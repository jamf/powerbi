[Version = "1.1.0"]
section JamfPro;

[DataSource.Kind="JamfPro", Publish="JamfPro.Publish"]

// gets initial jamf URL from user; uses this to make requests
shared JamfPro.Contents =Value.ReplaceType(
    JamfPro.JamfNavTable,
    type function (
        jamfUrl as (
            type text meta [
                Documentation.FieldCaption = "Jamf Pro Instance URL",
                Documentation.FieldDescription = "The Jamf Pro URL for your specific instance. This is the same one you use to log into your instance.",
                Documentation.FieldSampleValues = {"https://acme.jamfcloud.com"}
            ]
        )
    ) as text);


// sets initial navigation table that links to individual table queries
shared JamfPro.JamfNavTable = (url as text) as table =>
    let
        url = validateUrlScheme(url),
        pages_table = initializeComputerRecord(url),
        pages_table_mobile = initializeMobileRecord(url),
        computer_device_groups = initializeComputerGroupRecord(url),
        mobile_device_groups = initializeMobileGroupRecord(url),
        source = #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, {
            { "Computers", computersImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Groups", computerGroupsImplementation(computer_device_groups), "Table", "Table", true},
            { "Computers - Applications", computerApplicationsImplementation(url, pages_table), "Table", "Table", true},
            { "Mobile Devices", mobileDevicesImplementation(url, pages_table_mobile), "Table", "Table", true },
            { "Mobile Devices - Applications", mobileDevicesApplicationsImplementation(url, pages_table_mobile), "Table", "Table", true},
            { "Mobile Devices - Groups", mobileDevicesGroupsImplementation(mobile_device_groups), "Table", "Table", true}
        }),
        navTable = Table.ToNavigationTable(source, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

// simple function to validate that URL is in correct format
validateUrlScheme = (url as text) as text => if (Uri.Parts(url)[Scheme] <> "https") then error "Url scheme must be HTTPS" else url;

// initialization functions: 
// these functions set the page tables for the global records
initializeComputerRecord = (url as text) as table =>
    let
        // number of total devices in computer inventory record
        devices_count = UAPIResource(url, "uapi/v1/computers-inventory")[totalCount],
        pageSize = 100,
        pages = Number.RoundDown(devices_count/pageSize),
        page_list = {1..pages},
        pages_table = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table;

initializeMobileRecord = (url as text) as table =>
    let
        devices_count = UAPIResource(url, "uapi/v2/mobile-devices")[totalCount],
        pageSize = 100,
        pages = Number.RoundDown(devices_count/pageSize),
        page_list = {1..pages},
        pages_table_mobile = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table_mobile;

initializeMobileGroupRecord = (url as text) as table =>
    let 
        jsonDeviceGroups = JSSResource(url, "/mobiledevicegroups"),
        deviceGroups = Table.FromRecords(jsonDeviceGroups[mobile_device_groups]),
        deviceGroupsModified = Table.AddColumn(
            deviceGroups,
            "mobileDeviceGroupDetails", 
            each getMobileDeviceGroupDetails([id],url),
            type record
        )
    in
        deviceGroupsModified;

initializeComputerGroupRecord = (url as text) as table =>
    let 
        jsonComputerGroups = JSSResource(url, "/computergroups"),
        computerGroups = Table.FromRecords(jsonComputerGroups[computer_groups]),
        computerGroupsModified = Table.AddColumn(
            computerGroups, 
            "computerGroupDetails", 
            each getComputerGroupDetails([id], url),
            type record
        )
    in
        computerGroupsModified;
// this function acts as our API call for queries
UAPIResource = (baseUrl as text, relativepath as text, optional query as record, optional token as text, optional attempts as number) =>
    let 
        number_of_attempts = if attempts = null then 1 else (attempts + 1),
        
        response = if token = null then Web.Contents(baseUrl,
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = TokenAuthorizationHeader(baseUrl)
            ],
            RelativePath = relativepath,
            ManualStatusHandling = {429, 401},
            IsRetry = attempts <> null,
            Query = query
        ])
        else Web.Contents(baseUrl,
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
        ]),

        responseMetadata = Value.Metadata(response),
        responseCode = responseMetadata[Response.Status],
        responseHeaders = responseMetadata[Headers],

        json = if responseCode <> 200 and number_of_attempts < 3 then Function.InvokeAfter(() =>
            @UAPIResource(baseUrl, relativepath, query, TokenAuthorizationHeader(baseUrl, true), number_of_attempts), #duration(0,0,0,3)
        ) else Json.Document(response)
    in
        json;

// this function is the API call for classic Jamf Pro API data
JSSResource = (baseUrl as text, relativepath as text, optional token as text, optional attempts as number) =>
    let 
        numberOfAttempts = if attempts = null then 1 else (attempts + 1),
        response = if token = null then Web.Contents(baseUrl & "/JSSResource",
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = TokenAuthorizationHeader(baseUrl)          
            ],
            RelativePath = relativepath
        ])
        else Web.Contents(baseUrl,
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = token
            ],
            RelativePath = relativepath,
            Timeout = Duration.FromText("01:00:00.0"),
            ManualStatusHandling = {429, 401},
            IsRetry = attempts <> null
        ]),
        responseMetadata = Value.Metadata(response),
        responseCode = responseMetadata[Response.Status],
        responseHeaders = responseMetadata[Headers],
        json = if responseCode <> 200 and numberOfAttempts < 3 then Function.InvokeAfter(() => @JSSResource(baseUrl, relativepath, TokenAuthorizationHeader(baseUrl, true), numberOfAttempts), #duration(0,0,0,3))
        else Json.Document(response)
    in
        json;


// gets token for auth header in API call
TokenAuthorizationHeader = (baseUrl as text, optional isRetry as logical) =>
    let
        token = Json.Document(Web.Contents(baseUrl, [
            Headers = [],
            RelativePath = "/api/v1/auth/token",
            Content = Text.ToBinary(""),
            IsRetry = if isRetry <> null then isRetry else false
        ]))[token],
        token_header = "Bearer " & token
    in
        token_header;

// implementation functions:
// these correspond directly with their named table in the JamfNavTable 
// these queries handle getting the specific data and setting table with types
// start of computers queries
computersImplementation = (baseUrl as text, pages_table as table) as table =>
    let
        
        sections = List.Transform({
            "General",
            "Hardware",
            "Operating_System",
            "User_And_Location",
            "Purchasing",
            "Disk_Encryption",
            "Security"
        }, Text.Upper),

        pageSize = "100",


        temp_table = Table.AddColumn(
            pages_table,
            "response", 
            each Table.FromRecords(
                UAPIResource(baseUrl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results]
            )
        ),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.RemoveColumns(computer_table, "extensionAttributes"),
        expand_general = Table.ExpandRecordColumn(selected_table,
            "general",
            {"name",
                "lastIpAddress",
                "lastReportedIp",
                "jamfBinaryVersion",
                "platform","barcode1",
                "barcode2","assetTag",
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
                "enrollmentMethod"}
        ),
        expand_disk_encryption = Table.ExpandRecordColumn(expand_general, 
            "diskEncryption",               
            {"individualRecoveryKeyValidityStatus",
                "institutionalRecoveryKeyPresent",
                "diskEncryptionConfigurationName",
                "fileVault2EligibilityMessage",
                "fileVault2EnabledUserNames",
                "bootPartitionEncryptionDetails"}
        ),
        expand_purchasing = Table.ExpandRecordColumn(expand_disk_encryption, 
            "purchasing",
            {"purchased",
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
                "warrantyDate"}
        ),
        expand_user_and_location = Table.ExpandRecordColumn(expand_purchasing, 
            "userAndLocation", 
            {"username",
                "realname",
                "email",
                "position",
                "phone",
                "departmentId",
                "buildingId",
                "room"}
        ),
        expand_hardware = Table.ExpandRecordColumn(expand_user_and_location, 
            "hardware",
            {"make",
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
            "appleSilicon"}
        ),
        expand_operating_system = Table.ExpandRecordColumn(expand_hardware, 
            "operatingSystem", 
            {"name",
            "version",
            "build",
            "activeDirectoryStatus",
            "fileVault2Status",
            "softwareUpdateDeviceId"}, 
            {"os name",
            "os version",
            "os build",
            "activeDirectoryStatus",
            "fileVault2Status",
            "softwareUpdateDeviceId"}
        ),
        expand_remote_management = Table.ExpandRecordColumn(expand_operating_system,
            "remoteManagement",
            {"managed",
            "managementUsername"}
        ),
        expand_mdm_capable = Table.ExpandRecordColumn(expand_remote_management,
            "mdmCapable",
            {"capable",
            "capableUsers"}
        ),
        expand_site = Table.ExpandRecordColumn(expand_mdm_capable,
            "site",
            {"id",
            "name"},
            {"siteId",
            "siteName"}
        ),
        expand_fileVault2_enabled_usernames = Table.ExpandListColumn(expand_site, "fileVault2EnabledUserNames"),
        expand_security = Table.ExpandRecordColumn(expand_fileVault2_enabled_usernames, 
            "security",
            {"sipStatus",
            "gatekeeperStatus",
            "xprotectVersion",
            "autoLoginDisabled",
            "remoteDesktopEnabled",
            "activationLockEnabled",
            "secureBootLevel",
            "externalBootLevel",
            "bootstrapTokenAllowed",
            "recoveryLockEnabled",
            "firewallEnabled"}
        )
    in
        expand_security;

computerApplicationsImplementation = (baseUrl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Applications"
        }, Text.Upper),

        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "applications"}),
        expand_applications = Table.ExpandListColumn(selected_table, "applications"),
        filtered_table = Table.SelectRows(expand_applications, each [applications] <> null),
        expand_applications2 = Table.ExpandRecordColumn(filtered_table, "applications", {"name", "path", "version", "macAppStore", "sizeMegabytes", "bundleId", "updateAvailable", "externalVersionId"})
    in
        expand_applications2;


// start of mobile device queries
mobileDevicesImplementation = (baseUrl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "General",
            "Hardware",
            "Security"
        }, Text.Upper),

        pageSize = "100",

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
            each Table.FromRecords(
                UAPIResource(baseUrl, "uapi/v2/mobile-devices/detail", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results],
                column_names,
                MissingField.UseNull
            )
        ),

        mobile_devices_table = Table.Combine(temp_table_mobile[response]),
        selected_table = Table.RemoveColumns(mobile_devices_table, "extensionAttributes"),
        expand_hardware = Table.ExpandRecordColumn(selected_table,
            "hardware",
            {"capacityMb",
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
            "hardware.extensionAttributes"}
        ),
        expand_general = Table.ExpandRecordColumn(expand_hardware,
            "general",
            {"udid",
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
            "tethered"}
        ),
        null_updates = Table.TransformColumns(expand_general, {{"security", each if _ = null then [] else _}}),
        expand_security = Table.ExpandRecordColumn(null_updates,
            "security",
            {"dataProtected",
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
            "lostModeEnabledDate"}
        )
    in
        expand_security;

mobileDevicesApplicationsImplementation = (baseUrl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Applications"
        }, Text.Upper),

        pageSize = "100",

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
            each Table.FromRecords(
                UAPIResource(baseUrl, "uapi/v2/mobile-devices/detail", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results],
            column_names,
            MissingField.UseNull
            )),
        mobile_devices_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(mobile_devices_table, {"mobileDeviceId", "applications"}),
        expand_applications = Table.ExpandListColumn(selected_table, "applications"),
        filtered_table = Table.SelectRows(expand_applications, each [applications] <> null),
        expand_applications2 = Table.ExpandRecordColumn(
            filtered_table, 
            "applications", 
            {"identifier", 
            "name", 
            "version", 
            "shortVersion", 
            "managementStatus", 
            "validationStatus", 
            "bundleSize", 
            "dynamicSize"}
        )
    in
        expand_applications2;


mobileDevicesGroupsImplementation = (deviceGroups as table) as table =>
    let
        expandedTable = Table.ExpandRecordColumn(
            deviceGroups, 
            "mobileDeviceGroupDetails", 
            {"criteria",
            "site",
            "mobile_devices"}
        ),
        expandedSite = Table.ExpandRecordColumn(
            expandedTable,
            "site",
            {"id",
            "name"},
            {"site.id",
            "site.name"}
        )
    in
        expandedSite;

getMobileDeviceGroupDetails = (id as number, baseUrl as text) as any =>
    let 
        jsonDeviceGroupDetails = JSSResource(baseUrl, "/mobiledevicegroups/id/" & Number.ToText(id)),
        device_group_record = jsonDeviceGroupDetails[mobile_device_group],
        group_criteria_list = device_group_record[criteria],
        group_site_record = device_group_record[site],
        group_devices_list = device_group_record[mobile_devices],
        list_of_device_group_values = {
            group_criteria_list,
            group_site_record,
            group_devices_list
        },
        result = Record.FromList(
            list_of_device_group_values,
            {
                "criteria",
                "site",
                "mobile_devices"
            }
        )
    in
        result;

getComputerGroupDetails = (id as number, baseUrl as text) as record =>
    let
        jsonComputerGroupDetails = JSSResource(baseUrl, "/computergroups/id/" & Number.ToText(id)),
        computer_group_record = jsonComputerGroupDetails[computer_group],
        group_site_record = computer_group_record[site],
        group_criteria_list = computer_group_record[criteria],
        group_computers_list = computer_group_record[computers],
        list_of_computer_group_values = {
            group_site_record,
            group_criteria_list,
            group_computers_list
        },
        result = Record.FromList(
            list_of_computer_group_values,
            {
                "site",
                "criteria",
                "computers"
            }
        )
    in
        result;

computerGroupsImplementation = (computerGroups as table) as table =>
    let
        computerGroupsExpanded = Table.ExpandRecordColumn(
        computerGroups,
        "computerGroupDetails",
        {"site",
        "criteria",
        "computers"}
        ),
        sitesExpanded = Table.ExpandRecordColumn(
            computerGroupsExpanded,
            "site",
            {"id",
            "name"},
            {"site.id",
            "site.name"}
        )
    in
        sitesExpanded;
 
// Data Source Kind description
JamfPro = [
    TestConnection = (dataSourcePath) => {"JamfPro.Contents", dataSourcePath},
    Authentication = [
        UsernamePassword = [
            UsernameLabel="Enter your Jamf Pro username: ",
            PasswordLabel="Enter your Jamf Pro password: "
        ]
    ],
    Label = Extension.LoadString("JamfPro_URL")
];

// Data Source UI publishing description
JamfPro.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { "Jamf Pro", "Access your organization's Jamf Pro model" },
    LearnMoreUrl = "https://www.jamf.com/",
    SourceImage = JamfPro__Get_Devices.Icons,
    SourceTypeImage = JamfPro__Get_Devices.Icons
];

JamfPro__Get_Devices.Icons = [
    Icon16 = { Extension.Contents("JamfPro16.png"), Extension.Contents("JamfPro20.png"), Extension.Contents("JamfPro24.png"), Extension.Contents("JamfPro32.png") },
    Icon32 = { Extension.Contents("JamfPro32.png"), Extension.Contents("JamfPro40.png"), Extension.Contents("JamfPro48.png"), Extension.Contents("JamfPro64.png") }
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
