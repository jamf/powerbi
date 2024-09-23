[Version = "2.0.0"]
section JamfPro;

pageSize = 100;

[DataSource.Kind = "JamfPro", Publish = "JamfPro.Publish"]
// gets initial jamf URL from user; uses this to make requests
shared JamfPro.Contents = Value.ReplaceType(
    JamfPro.JamfNavTable,
    type function (
        jamfUrl as (
            type text meta [
                Documentation.Name = "URL",
                Documentation.FieldCaption = "Jamf Pro URL",
                Documentation.FieldDescription = "The URL for your Jamf Pro instance",
                Documentation.FieldSampleValues = {"https://acme.jamfcloud.com"}
            ]
        ),
        optional authType as (
            type text meta [
                Documentation.Name = "Authentication",
                Documentation.FieldCaption = "Authentication Type",
                Documentation.FieldDescription = "Authentication type for connecting to your Jamf Pro instance. Default is UsernamePassword.",
                Documentation.AllowedValues = {"UsernamePassword", "ClientCredentials"}
            ]
        )
    ) as text meta [
        Documentation.Name = "Jamf Pro"
    ]
);

// sets initial navigation table that links to individual table queries
shared JamfPro.JamfNavTable = (url as text, optional authType as text) as table =>
    let
        url = validateUrlScheme(url),
        authType = if authType = null then "UsernamePassword" else validateAuthType(authType),
        computerPageCount = getTotalNumberOfPages(url, authType, "v1/computers-inventory"),
        pages_table = initializeComputerRecord(url, authType),
        pages_table_mobile = initializeMobileRecord(url, authType),
        computer_device_groups = initializeComputerGroupRecord(url, authType),
        mobile_device_groups = initializeMobileGroupRecord(url, authType),
        source = #table(
            {"Name", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Computers", computersImplementation(url, authType, pages_table), "Table", "Table", true},
                {"Computer Device Groups", computer_device_groups, "Table", "Table", true},
                {
                    "Computers - Applications",
                    getComputerApplications(url, authType, computerPageCount),
                    "Table",
                    "Table",
                    true
                },
                {
                    "Mobile Devices",
                    mobileDevicesImplementation(url, authType, pages_table_mobile),
                    "Table",
                    "Table",
                    true
                },
                {
                    "Mobile Devices - Applications",
                    mobileDevicesApplicationsImplementation(url, authType, pages_table_mobile),
                    "Table",
                    "Table",
                    true
                },
                {"Mobile Device Groups", mobile_device_groups, "Table", "Table", true}
            }
        ),
        navTable = Table.ToNavigationTable(source, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

// simple function to validate that URL is in correct format
validateUrlScheme = (url as text) as text =>
    if (Uri.Parts(url)[Scheme] <> "https") then
        error "Url scheme must be HTTPS"
    else
        removeTrailingSlash(url);
validateAuthType = (authType as text) as text =>
    if (authType <> "ClientCredentials" and authType <> "UsernamePassword") then
        "UsernamePassword"
    else
        authType;

removeTrailingSlash = (url as text) as text =>
    if Text.EndsWith(url, "/") then
        Text.RemoveRange(url, Text.Length(url) - 1, 1)
    else
        url;

getTotalNumberOfPages = (url as text, authType as text, relativePath as text) as number =>
    let
        devices_count = UAPIResource(
            url, authType, "api/" & relativePath, [#"page-size" = Text.From(pageSize)]
        )[totalCount],
        pages = if devices_count = 0 then 0 else Number.RoundUp(devices_count / pageSize)
    in
        pages;

getComputersOnePage = (url as text, authType as text, sections as list, page as number) as list =>
    let
        result = UAPIResource(
            url,
            authType,
            "api/v1/computers-inventory",
            [
                page = Text.From(page),
                #"page-size" = Text.From(pageSize),
                section = sections
            ]
        )[results]
    in
        result;

// initialization functions:
// these functions set the page tables for the global records
initializeComputerRecord = (url as text, authType as text) as table =>
    let
        // number of total devices in computer inventory record
        devices_count = UAPIResource(url, authType, "api/v1/computers-inventory")[totalCount],
        pages = Number.RoundDown(devices_count / pageSize),
        page_list = {1..pages},
        pages_table = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table;

initializeMobileRecord = (url as text, authType as text) as table =>
    let
        devices_count = UAPIResource(url, authType, "api/v2/mobile-devices")[totalCount],
        pages = Number.RoundDown(devices_count / pageSize),
        page_list = {1..pages},
        pages_table_mobile = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table_mobile;

initializeMobileGroupRecord = (url as text, authType as text) as table =>
    let
        jsonDeviceGroups = JSSResource(url, authType, "/mobiledevicegroups"),
        deviceGroups = Table.FromRecords(jsonDeviceGroups[mobile_device_groups]),
        selectedColumns = Table.SelectColumns(deviceGroups, {"id", "name", "is_smart"}),
        groupsPlusMembership = Table.AddColumn(
            selectedColumns, "temp_column", each getMobileDeviceMembership([id], url, authType), type list
        ),
        tempTable = Table.ExpandListColumn(groupsPlusMembership, "temp_column"),
        mobileDeviceGroupExpanded = Table.ExpandRecordColumn(
            tempTable,
            "temp_column",
            {"id", "name", "mac_address", "udid", "wifi_mac_address", "serial_number"},
            {
                "device_id",
                "device_name",
                "device_mac_address",
                "device_udid",
                "device_wifi_mac_address",
                "device_serial_number"
            }
        )
    in
        mobileDeviceGroupExpanded;

initializeComputerGroupRecord = (url as text, authType as text) as table =>
    let
        jsonComputerGroups = JSSResource(url, authType, "/computergroups"),
        computerGroups = Table.FromRecords(jsonComputerGroups[computer_groups]),
        selectedColumns = Table.SelectColumns(computerGroups, {"id", "name", "is_smart"}),
        computerGroupsModified = Table.AddColumn(
            selectedColumns, "temp_column", each getComputerGroupMembershipIds([id], url, authType), type list
        ),
        tempTable = Table.ExpandListColumn(computerGroupsModified, "temp_column"),
        computerGroupsModifiedExpanded = Table.ExpandRecordColumn(
            tempTable, "temp_column", {"id", "name"}, {"computer_id", "computer_name"}
        )
    in
        computerGroupsModifiedExpanded;

getComputerGroupMembershipIds = (id as number, baseUrl as text, authType as text) as list =>
    let
        jsonComputerGroupMembers = JSSResource(baseUrl, authType, "/computergroups/id/" & Number.ToText(id)),
        computerGroupMembers = try jsonComputerGroupMembers[computer_group][computers] as list otherwise {}
    in
        computerGroupMembers;

getMobileDeviceMembership = (id as number, baseUrl as text, authType as text) as list =>
    let
        jsonMobileDeviceGroupMembers = JSSResource(baseUrl, authType, "/mobiledevicegroups/id/" & Number.ToText(id)),
        mobileDeviceGroupMembers =
            try jsonMobileDeviceGroupMembers[mobile_device_group][mobile_devices] as list otherwise {}
    in
        mobileDeviceGroupMembers;

// this function acts as our API call for queries
UAPIResource = (
    baseUrl as text,
    authType as text,
    relativepath as text,
    optional query as record,
    optional token as text,
    optional attempts as number
) =>
    let
        number_of_attempts = if attempts = null then 1 else (attempts + 1),
        response =
            if token = null then
                Web.Contents(
                    baseUrl,
                    [
                        Headers = [
                            #"Accept" = "application/json",
                            #"Authorization" = TokenAuthorizationHeader(baseUrl, authType)
                        ],
                        RelativePath = relativepath,
                        ManualStatusHandling = {429, 401},
                        IsRetry = attempts <> null,
                        Query = query
                    ]
                )
            else
                Web.Contents(
                    baseUrl,
                    [
                        Headers = [
                            #"Accept" = "application/json",
                            #"Authorization" = token
                        ],
                        RelativePath = relativepath,
                        Timeout = Duration.FromText("01:00:00.0"),
                        ManualStatusHandling = {429, 401},
                        IsRetry = attempts <> null,
                        Query = query
                    ]
                ),
        responseMetadata = Value.Metadata(response),
        responseCode = responseMetadata[Response.Status],
        responseHeaders = responseMetadata[Headers],
        json =
            if responseCode <> 200 and number_of_attempts < 3 then
                Function.InvokeAfter(
                    () =>
                        @UAPIResource(
                            baseUrl,
                            authType,
                            relativepath,
                            query,
                            TokenAuthorizationHeader(baseUrl, authType, true),
                            number_of_attempts
                        ),
                    #duration(0, 0, 0, 3)
                )
            else
                Json.Document(response)
    in
        json;

// this function is the API call for classic Jamf Pro API data
JSSResource = (
    baseUrl as text, authType as text, relativepath as text, optional token as text, optional attempts as number
) =>
    let
        numberOfAttempts = if attempts = null then 1 else (attempts + 1),
        response =
            if token = null then
                Web.Contents(
                    baseUrl & "/JSSResource",
                    [
                        Headers = [
                            #"Accept" = "application/json",
                            #"Authorization" = TokenAuthorizationHeader(baseUrl, authType)
                        ],
                        RelativePath = relativepath
                    ]
                )
            else
                Web.Contents(
                    baseUrl,
                    [
                        Headers = [
                            #"Accept" = "application/json",
                            #"Authorization" = token
                        ],
                        RelativePath = relativepath,
                        Timeout = Duration.FromText("01:00:00.0"),
                        ManualStatusHandling = {429, 401},
                        IsRetry = attempts <> null
                    ]
                ),
        responseMetadata = Value.Metadata(response),
        responseCode = responseMetadata[Response.Status],
        responseHeaders = responseMetadata[Headers],
        json =
            if responseCode <> 200 and numberOfAttempts < 3 then
                Function.InvokeAfter(
                    () =>
                        @JSSResource(
                            baseUrl, authType, relativepath, TokenAuthorizationHeader(baseUrl, true),
                            numberOfAttempts
                        ),
                    #duration(0, 0, 0, 3)
                )
            else
                Json.Document(response)
    in
        json;

// gets token for auth header in API call
TokenAuthorizationHeader = (baseUrl as text, authType as text, optional isRetry as logical) =>
    let
        credentials = Extension.CurrentCredential(),
        token =
            if authType = "UsernamePassword" then
                Json.Document(
                    Web.Contents(
                        baseUrl,
                        [
                            Headers = [],
                            RelativePath = "/api/v1/auth/token",
                            Content = Text.ToBinary(""),
                            IsRetry = if isRetry <> null then isRetry else false
                        ]
                    )
                )[token]
            else if authType = "ClientCredentials" then
                Json.Document(
                    Web.Contents(
                        baseUrl,
                        [
                            Headers = [#"Content-Type" = "application/x-www-form-urlencoded"],
                            RelativePath = "/api/v1/oauth/token",
                            Content = Text.ToBinary(
                                "client_id="
                                    & credentials[Username]
                                    & "&client_secret="
                                    & credentials[Password]
                                    & "&grant_type=client_credentials"
                            ),
                            IsRetry = if isRetry <> null then isRetry else false
                        ]
                    )
                )[access_token]
            else
                error "Unsupported authType",
        token_header = "Bearer " & token
    in
        token_header;

// implementation functions:
// these correspond directly with their named table in the JamfNavTable
// these queries handle getting the specific data and setting table with types
// start of computers queries
computersImplementation = (baseUrl as text, authType as text, pages_table as table) as table =>
    let
        sections = List.Transform(
            {
                "General",
                "Hardware",
                "Operating_System",
                "User_And_Location",
                "Purchasing",
                "Disk_Encryption",
                "Security"
            },
            Text.Upper
        ),
        temp_table = Table.AddColumn(
            pages_table,
            "response",
            each
                Table.FromRecords(
                    UAPIResource(
                        baseUrl,
                        authType,
                        "api/v1/computers-inventory",
                        [
                            #"page-size" = Text.From(pageSize),
                            page = Text.From(Number.From(_[Column1]) - 1),
                            section = sections
                        ]
                    )[results]
                )
        ),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = try Table.RemoveColumns(computer_table, "extensionAttributes") otherwise computer_table,
        expand_general =
            try
                Table.ExpandRecordColumn(
                    selected_table,
                    "general",
                    {
                        "name",
                        "lastIpAddress",
                        "lastReportedIp",
                        "jamfBinaryVersion",
                        "platform",
                        "barcode1",
                        "barcode2",
                        "assetTag",
                        "remoteManagement",
                        "supervised",
                        "mdmCapable",
                        "reportDate",
                        "lastContactTime",
                        "lastCloudBackupDate",
                        "lastEnrolledDate",
                        "mdmProfileExpiration",
                        "initialEntryDate",
                        "distributionPoint",
                        "site",
                        "itunesStoreAccountActive",
                        "enrolledViaAutomatedDeviceEnrollment",
                        "userApprovedMdm",
                        "enrollmentMethod"
                    }
                ) otherwise selected_table,
        expand_disk_encryption =
            try
                Table.ExpandRecordColumn(
                    expand_general,
                    "diskEncryption",
                    {
                        "individualRecoveryKeyValidityStatus",
                        "institutionalRecoveryKeyPresent",
                        "diskEncryptionConfigurationName",
                        "fileVault2EligibilityMessage",
                        "fileVault2EnabledUserNames",
                        "bootPartitionEncryptionDetails"
                    }
                ) otherwise expand_general,
        expand_purchasing =
            try
                Table.ExpandRecordColumn(
                    expand_disk_encryption,
                    "purchasing",
                    {
                        "purchased",
                        "leased",
                        "poNumber",
                        "lifeExpectancy",
                        "purchasePrice",
                        "purchasingAccount",
                        "purchasingContact",
                        "appleCareId",
                        "vendor",
                        "leaseDate",
                        "poDate",
                        "warrantyDate"
                    }
                ) otherwise expand_disk_encryption,
        expand_user_and_location =
            try
                Table.ExpandRecordColumn(
                    expand_purchasing,
                    "userAndLocation",
                    {"username", "realname", "email", "position", "phone", "departmentId", "buildingId", "room"}
                ) otherwise expand_purchasing,
        expand_hardware =
            try
                Table.ExpandRecordColumn(
                    expand_user_and_location,
                    "hardware",
                    {
                        "make",
                        "model",
                        "modelIdentifier",
                        "serialNumber",
                        "processorSpeedMhz",
                        "processorCount",
                        "coreCount",
                        "processorType",
                        "processorArchitecture",
                        "busSpeedMhz",
                        "cacheSizeKilobytes",
                        "networkAdapterType",
                        "macAddress",
                        "altNetworkAdapterType",
                        "altMacAddress",
                        "totalRamMegabytes",
                        "openRamSlots",
                        "batteryCapacityPercent",
                        "smcVersion",
                        "nicSpeed",
                        "opticalDrive",
                        "bootRom",
                        "bleCapable",
                        "supportsIosAppInstalls",
                        "appleSilicon"
                    }
                ) otherwise expand_user_and_location,
        expand_operating_system =
            try
                Table.ExpandRecordColumn(
                    expand_hardware,
                    "operatingSystem",
                    {
                        "name",
                        "version",
                        "build",
                        "activeDirectoryStatus",
                        "fileVault2Status",
                        "softwareUpdateDeviceId"
                    },
                    {
                        "os name",
                        "os version",
                        "os build",
                        "activeDirectoryStatus",
                        "fileVault2Status",
                        "softwareUpdateDeviceId"
                    }
                ) otherwise expand_hardware,
        expand_remote_management =
            try
                Table.ExpandRecordColumn(
                    expand_operating_system, "remoteManagement", {"managed", "managementUsername"}
                ) otherwise expand_operating_system,
        expand_mdm_capable =
            try
                Table.ExpandRecordColumn(expand_remote_management, "mdmCapable", {"capable", "capableUsers"})
            otherwise
                expand_remote_management,
        expand_site =
            try
                Table.ExpandRecordColumn(expand_mdm_capable, "site", {"id", "name"}, {"siteId", "siteName"})
            otherwise
                expand_mdm_capable,
        expand_fileVault2_enabled_usernames =
            try Table.ExpandListColumn(expand_site, "fileVault2EnabledUserNames") otherwise expand_site,
        expand_security =
            try
                Table.ExpandRecordColumn(
                    expand_fileVault2_enabled_usernames,
                    "security",
                    {
                        "sipStatus",
                        "gatekeeperStatus",
                        "xprotectVersion",
                        "autoLoginDisabled",
                        "remoteDesktopEnabled",
                        "activationLockEnabled",
                        "secureBootLevel",
                        "externalBootLevel",
                        "bootstrapTokenAllowed",
                        "recoveryLockEnabled",
                        "firewallEnabled"
                    }
                ) otherwise expand_fileVault2_enabled_usernames
    in
        expand_security;

getComputerApplications = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        fieldNamesFromApi = {"name", "path", "version"},
        fieldNamesForTable = {
            "computerDetails.computerApplications.name",
            "computerDetails.computerApplications.path",
            "computerDetails.computerApplications.version"
        },

        emptyTable = #table(List.Combine({{"id"}, fieldNamesForTable}), {}),
        result =
            if totalPagesCount = 0 then
                emptyTable
            else
                let
                    pages = {0..totalPagesCount - 1},
                    listOfPages = List.Transform(
                        pages, each getComputersOnePage(url, authType, {"GENERAL, APPLICATIONS"}, _)
                    ),
                    rowPerComputer = List.Combine(listOfPages),
                    data = Table.FromRecords(rowPerComputer),
                    selectedColumns = Table.SelectColumns(data, {"id", "general", "applications"}),
                    expandGeneral = Table.ExpandRecordColumn(selectedColumns, "general", {"name"}),
                    expandApplications = Table.ExpandListColumn(expandGeneral, "applications"),
                    expandedApplicationsWithFieldNames = Table.ExpandRecordColumn(
                        expandApplications, "applications", fieldNamesFromApi, fieldNamesForTable
                    )
                in
                    expandedApplicationsWithFieldNames
    in
        result;


// start of mobile device queries
mobileDevicesImplementation = (baseUrl as text, authType as text, pages_table as table) as table =>
    let
        sections = List.Transform({"General", "Hardware", "Security"}, Text.Upper),
        column_names = {
            "mobileDeviceId",
            "deviceType",
            "hardware",
            "userAndLocation",
            "purchasing",
            "applications",
            "certificates",
            "profiles",
            "userProfiles",
            "extensionAttributes",
            "general",
            "security",
            "ebooks",
            "network",
            "serviceSubscriptions",
            "provisioningProfiles",
            "sharedUsers"
        },
        temp_table_mobile = Table.AddColumn(
            pages_table,
            "response",
            each
                Table.FromRecords(
                    UAPIResource(
                        baseUrl,
                        authType,
                        "api/v2/mobile-devices/detail",
                        [
                            #"page-size" = Text.From(pageSize),
                            page = Text.From(Number.From(_[Column1]) - 1),
                            section = sections
                        ]
                    )[results],
                    column_names,
                    MissingField.UseNull
                )
        ),
        mobile_devices_table = Table.Combine(temp_table_mobile[response]),
        selected_table =
            try Table.RemoveColumns(mobile_devices_table, "extensionAttributes") otherwise mobile_devices_table,
        expand_hardware =
            try
                Table.ExpandRecordColumn(
                    selected_table,
                    "hardware",
                    {
                        "capacityMb",
                        "availableSpaceMb",
                        "usedSpacePercentage",
                        "batteryLevel",
                        "serialNumber",
                        "wifiMacAddress",
                        "bluetoothMacAddress",
                        "modemFirmwareVersion",
                        "model",
                        "modelIdentifier",
                        "modelNumber",
                        "bluetoothLowEnergyCapable",
                        "deviceId",
                        "hardware.extensionAttributes"
                    }
                ) otherwise selected_table,
        expand_general =
            try
                Table.ExpandRecordColumn(
                    expand_hardware,
                    "general",
                    {
                        "udid",
                        "displayName",
                        "assetTag",
                        "siteId",
                        "lastInventoryUpdateDate",
                        "osVersion",
                        "osRapidSecurityResponse",
                        "osBuild",
                        "osSupplementalBuildVersion",
                        "softwareUpdateDeviceId",
                        "ipAddress",
                        "managed",
                        "supervised",
                        "deviceOwnershipType",
                        "enrollmentMethodPrestage",
                        "enrollmentSessionTokenValid",
                        "lastEnrolledDate",
                        "mdmProfileExpirationDate",
                        "timeZone",
                        "declarativeDeviceManagementEnabled",
                        "general.extensionAttributes",
                        "sharedIpad",
                        "diagnosticAndUsageReportingEnabled",
                        "appAnalyticsEnabled",
                        "residentUsers",
                        "quotaSize",
                        "temporarySessionOnly",
                        "temporarySessionTimeout",
                        "userSessionTimeout",
                        "syncedToComputer",
                        "maximumSharediPadUsersStored",
                        "lastBackupDate",
                        "deviceLocatorServiceEnabled",
                        "doNotDisturbEnabled",
                        "cloudBackupEnabled",
                        "lastCloudBackupDate",
                        "locationServicesForSelfServiceMobileEnabled",
                        "itunesStoreAccountActive",
                        "exchangeDeviceId",
                        "tethered"
                    }
                ) otherwise expand_hardware,
        null_updates =
            try
                Table.TransformColumns(expand_general, {{"security", each if _ = null then [] else _}})
            otherwise
                expand_general,
        expand_security =
            try
                Table.ExpandRecordColumn(
                    null_updates,
                    "security",
                    {
                        "dataProtected",
                        "blockLevelEncryptionCapable",
                        "fileLevelEncryptionCapable",
                        "passcodePresent",
                        "passcodeCompliant",
                        "passcodeCompliantWithProfile",
                        "hardwareEncryption",
                        "activationLockEnabled",
                        "jailBreakDetected",
                        "passcodeLockGracePeriodEnforcedSeconds",
                        "personalDeviceProfileCurrent",
                        "lostModeEnabled",
                        "lostModePersistent",
                        "lostModeMessage",
                        "lostModePhoneNumber",
                        "lostModeFootnote",
                        "lostModeLocation",
                        "lostModeEnabledDate"
                    }
                ) otherwise null_updates
    in
        expand_security;

mobileDevicesApplicationsImplementation = (baseUrl as text, authType as text, pages_table as table) as table =>
    let
        sections = List.Transform({"Applications"}, Text.Upper),
        column_names = {
            "mobileDeviceId",
            "deviceType",
            "hardware",
            "userAndLocation",
            "purchasing",
            "applications",
            "certificates",
            "profiles",
            "userProfiles",
            "extensionAttributes",
            "general",
            "security",
            "ebooks",
            "network",
            "serviceSubscriptions",
            "provisioningProfiles",
            "sharedUsers"
        },
        temp_table = Table.AddColumn(
            pages_table,
            "response",
            each
                Table.FromRecords(
                    UAPIResource(
                        baseUrl,
                        authType,
                        "api/v2/mobile-devices/detail",
                        [
                            #"page-size" = Text.From(pageSize),
                            page = Text.From(Number.From(_[Column1]) - 1),
                            section = sections
                        ]
                    )[results],
                    column_names,
                    MissingField.UseNull
                )
        ),
        mobile_devices_table = Table.Combine(temp_table[response]),
        selected_table =
            try
                Table.SelectColumns(mobile_devices_table, {"mobileDeviceId", "applications"})
            otherwise
                mobile_devices_table,
        expand_applications = try Table.ExpandListColumn(selected_table, "applications") otherwise selected_table,
        filtered_table =
            try Table.SelectRows(expand_applications, each [applications] <> null) otherwise expand_applications,
        expand_applications2 =
            try
                Table.ExpandRecordColumn(
                    filtered_table,
                    "applications",
                    {
                        "identifier",
                        "name",
                        "version",
                        "shortVersion",
                        "managementStatus",
                        "validationStatus",
                        "bundleSize",
                        "dynamicSize"
                    }
                ) otherwise filtered_table
    in
        expand_applications2;

// Data Source Kind description
JamfPro = [
    TestConnection = (dataSourcePath) => {"JamfPro.JamfNavTable", dataSourcePath},
    Authentication = [
        UsernamePassword = [
            UsernameLabel = "Username (or client ID)",
            PasswordLabel = "Password (or client secret)",
            Label = "Jamf Pro Credentials"
        ]
    ],
    Label = "Jamf Pro"
];

// Data Source UI publishing description
JamfPro.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = {"Jamf Pro", "Import data from Jamf Pro"},
    LearnMoreUrl = "https://www.jamf.com/",
    SourceImage = JamfPro__Get_Devices.Icons,
    SourceTypeImage = JamfPro__Get_Devices.Icons
];

JamfPro__Get_Devices.Icons = [
    Icon16 = {
        Extension.Contents("JamfPro16.png"),
        Extension.Contents("JamfPro20.png"),
        Extension.Contents("JamfPro24.png"),
        Extension.Contents("JamfPro32.png")
    },
    Icon32 = {
        Extension.Contents("JamfPro32.png"),
        Extension.Contents("JamfPro40.png"),
        Extension.Contents("JamfPro48.png"),
        Extension.Contents("JamfPro64.png")
    }
];

Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;
