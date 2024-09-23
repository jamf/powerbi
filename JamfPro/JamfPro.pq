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
        computerPages = getTotalNumberOfPages(url, authType, "v1/computers-inventory"),
        mobileDevicesPages = getTotalNumberOfPages(url, authType, "v2/mobile-devices"),
        pages_table = initializeComputerRecord(url, authType),
        source = #table(
            {"Name", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Computers", computersImplementation(url, authType, pages_table), "Table", "Table", true},
                {"Computer Device Groups", computerGroups(url, authType), "Table", "Table", true},
                {
                    "Computers - Applications",
                    computerApplications(url, authType, computerPages),
                    "Table",
                    "Table",
                    true
                },
                {"Mobile Devices", mobileDevices(url, authType, mobileDevicesPages),
                "Table", "Table", true},
                {
                    "Mobile - Applications",
                    mobileDeviceApplications(url, authType, mobileDevicesPages),
                    "Table",
                    "Table",
                    true
                },
                {"Mobile Device Groups", mobileDeviceGroups(url, authType), "Table", "Table", true}
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

getPageComputers = (url as text, authType as text, sections as list, page as number) as list =>
    getPage(url, authType, sections, page, "api/v1/computers-inventory", "id");

getPageMobileDevices = (url as text, authType as text, sections as list, page as number) as list =>
    getPage(url, authType, sections, page, "api/v2/mobile-devices/detail", "mobileDeviceId");

getPage = (url as text, authType as text, sections as list, page as number, path as text, sortKey as text) as list =>
    let
        result = UAPIResource(
            url,
            authType,
            path,
            [
                #"page-size" = Text.From(pageSize),
                page = Text.From(page),
                section = sections,
                sort = sortKey
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

mobileDeviceGroups = (url as text, authType as text) as table =>
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

computerGroups = (url as text, authType as text) as table =>
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

computerApplications = (url as text, authType as text, totalPagesCount as number) as table =>
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
                        pages, each getPageComputers(url, authType, {"GENERAL, APPLICATIONS"}, _)
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

// Mobile device lookup and mapping function.
//
// Notes about backward compatibility with the legacy 1.0.0-beta version of the connector:
// - `apiFields` are the fields returned by the API and `tableFields` are the fields that will
//   be displayed in the Power BI table. The remapping was necessary to limit the number of
//   changes to the legacy data model, in an effort to preserve existing data sets and
//   visualizations where possible.
// - Commented out fields in the `apiFields` lists do not have an analogue in the legacy data model
//   and are excluded at this time. They may be added in the future.
// - Fields in the `unmapped` list will be removed from legacy data models. Most of these are
//   duplicative (e.g., model/modelDisplay/model_display).
// - Dates are mapped to the _utc variant of the field name to match the legacy data model.
mobileDevices = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        apiFieldsTopLevel = {"mobileDeviceId", "deviceType"},
        tableFieldsTopLevel = {"id", "mobileDeviceDetails.os_type"},
        apiFieldsGeneral = {
            "udid",
            "displayName",
            "assetTag",
            "siteId",
            "lastInventoryUpdateDate",
            "osVersion",
            // "osRapidSecurityResponse"
            "osBuild",
            // "osSupplementalBuildVersion"
            // "softwareUpdateDeviceId",
            "ipAddress",
            "managed",
            "supervised",
            "deviceOwnershipType",
            // "enrollmentMethodPrestage",
            // "enrollmentSessionTokenValid",
            "lastEnrolledDate",
            // "mdmProfileExpirationDate",
            // "timeZone",
            // "declarativeDeviceManagementEnabled",
            // "extensionAttributes",
            "sharedIpad",
            // "diagnosticAndUsageReportingEnabled",
            // "appAnalyticsEnabled",
            // "residentUsers",
            // "quotaSize",
            // "temporarySessionOnly",
            // "temporarySessionTimeout",
            // "userSessionTimeout",
            // "syncedToComputer",
            // "maximumSharediPadUsersStored",
            "lastBackupDate",
            "deviceLocatorServiceEnabled",
            "doNotDisturbEnabled",
            "cloudBackupEnabled",
            "lastCloudBackupDate",
            // "locationServicesForSelfServiceMobileEnabled",
            "itunesStoreAccountActive",
            "exchangeDeviceId",
            "tethered"
        },
        tableFieldsGeneral = {
            "mobileDeviceDetails.udid",
            "name",
            "mobileDeviceDetails.asset_tag",
            // note, legacy connector maps this as a Record type (with the site's ID and name), but we're just mapping the ID
            "mobileDeviceDetails.site",
            "mobileDeviceDetails.last_inventory_update_utc",
            "mobileDeviceDetails.os_version",
            "mobileDeviceDetails.os_build",
            "mobileDeviceDetails.ip_address",
            "mobileDeviceDetails.managed",
            "mobileDeviceDetails.supervised",
            "mobileDeviceDetails.device_ownership_level",
            "mobileDeviceDetails.last_enrollment_utc",
            "mobileDeviceDetails.shared",
            "mobileDeviceDetails.last_backup_time_utc",
            "mobileDeviceDetails.device_locator_service_enabled",
            "mobileDeviceDetails.do_not_disturb_enabled",
            "mobileDeviceDetails.cloud_backup_enabled",
            "mobileDeviceDetails.last_cloud_backup_date_utc",
            "mobileDeviceDetails.itunes_store_account_is_active",
            "mobileDeviceDetails.exchange_activesync_device_identifier",
            "mobileDeviceDetails.tethered"
        },
        apiFieldsHardware = {
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
            "bluetoothLowEnergyCapable"
        },
        tableFieldsHardware = {
            "mobileDeviceDetails.capacity_mb",
            "mobileDeviceDetails.available_mb",
            "mobileDeviceDetails.percentage_used",
            "mobileDeviceDetails.battery_level",
            "mobileDeviceDetails.serial_number",
            "mobileDeviceDetails.wifi_mac_address",
            "mobileDeviceDetails.bluetooth_mac_address",
            "mobileDeviceDetails.modem_firmware",
            "mobileDeviceDetails.model",
            "mobileDeviceDetails.model_identifier",
            "mobileDeviceDetails.model_number",
            "mobileDeviceDetails.ble_capable"
        },
        apiFieldsUserAndLocation = {
            "username",
            "realName",
            "emailAddress",
            "position",
            "phoneNumber",
            "room",
            "building",
            "department"
        },
        tableFieldsUserAndLocation = {
            "mobileDeviceDetails.username",
            "mobileDeviceDetails.real_name",
            "mobileDeviceDetails.email_address",
            "mobileDeviceDetails.position",
            "mobileDeviceDetails.phone_number",
            "mobileDeviceDetails.room",
            "mobileDeviceDetails.building",
            "mobileDeviceDetails.department"
        },
        apiFieldsSecurity = {
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
            "lostModeEnabled",
            // "lostModePersistent", - not idenfied in legacy model
            "lostModeMessage",
            "lostModePhoneNumber",
            "lostModeFootnote",
            // expanded below
            "lostModeLocation", 
            "lostModeEnabledDate" 
        },
        tableFieldsSecurity = {
            "mobileDeviceDetails.data_protection",
            "mobileDeviceDetails.block_level_encryption_capable",
            "mobileDeviceDetails.file_level_encryption_capable",
            "mobileDeviceDetails.passcode_present",
            "mobileDeviceDetails.passcode_compliant",
            "mobileDeviceDetails.passcode_compliant_with_profile",
            "mobileDeviceDetails.hardware_encryption",
            "mobileDeviceDetails.activation_lock_enabled",
            "mobileDeviceDetails.jailbreak_detected",
            "mobileDeviceDetails.passcode_lock_grace_period_enforced",
            "mobileDeviceDetails.lost_mode_enabled",
            "mobileDeviceDetails.lost_mode_message",
            "mobileDeviceDetails.lost_mode_phone",
            "mobileDeviceDetails.lost_mode_footnote",
            // expanded below
            "lostModeLocation",
            "mobileDeviceDetails.lost_mode_enable_issued_utc"
        },
        apiFieldsLostModeLocation = {
            "lastLocationUpdate",
            "lostModeLocationHorizontalAccuracyMeters",
            "lostModeLocationVerticalAccuracyMeters",
            "lostModeLocationAltitudeMeters",
            "lostModeLocationSpeedMetersPerSecond",
            "lostModeLocationCourseDegrees",
            "lostModeLocationTimestamp"
        },
        tableFieldsLostModeLocation = {
            "mobileDeviceDetails.lost_location_utc",
            "mobileDeviceDetails.lost_location_horizontal_accuracy",
            "mobileDeviceDetails.lost_location_vertical_accuracy",
            "mobileDeviceDetails.lost_location_altitude",
            "mobileDeviceDetails.lost_location_speed",
            "mobileDeviceDetails.lost_location_course",
            "mobileDeviceDetails.lost_mode_location_timestamp"
        },
        apiFieldsNetwork = {
            "cellularTechnology",
            "voiceRoamingEnabled",
            "imei",
            "iccid",
            "meid",
            // "eid",
            "carrierSettingsVersion",
            "currentCarrierNetwork",
            "currentMobileCountryCode",
            "currentMobileNetworkCode",
            "homeCarrierNetwork",
            "homeMobileCountryCode",
            "homeMobileNetworkCode",
            "dataRoamingEnabled",
            "roaming",
            // "personalHotspotEnabled",
            "phoneNumber"
        },
        tableFieldsNetwork = {
            "mobileDeviceDetails.cellular_technology",
            "mobileDeviceDetails.voice_roaming_enabled",
            "mobileDeviceDetails.imei",
            "mobileDeviceDetails.iccid",
            "mobileDeviceDetails.meid",
            "mobileDeviceDetails.carrier_settings_version",
            "mobileDeviceDetails.current_carrier_network",
            "mobileDeviceDetails.current_mobile_country_code",
            "mobileDeviceDetails.current_mobile_network_code",
            "mobileDeviceDetails.home_carrier_network",
            "mobileDeviceDetails.home_mobile_country_code",
            "mobileDeviceDetails.home_mobile_network_code",
            "mobileDeviceDetails.data_roaming_enabled",
            "mobileDeviceDetails.roaming",
            "mobileDeviceDetails.phone"
        },
        apiFieldsPurchasing = {
            "purchased",
            "leased",
            "poNumber",
            "vendor",
            "appleCareId",
            "purchasePrice",
            "purchasingAccount",
            "poDate",
            "warrantyExpiresDate",
            "leaseExpiresDate",
            "lifeExpectancy",
            "purchasingContact"
        },
        tableFieldsPurchasing = {
            "mobileDeviceDetails.is_purchased",
            "mobileDeviceDetails.is_leased",
            "mobileDeviceDetails.po_number",
            "mobileDeviceDetails.vendor",
            "mobileDeviceDetails.applecare_id",
            "mobileDeviceDetails.purchase_price",
            "mobileDeviceDetails.purchasing_account",
            "mobileDeviceDetails.po_date",
            "mobileDeviceDetails.warranty_expires",
            "mobileDeviceDetails.lease_expires",
            "mobileDeviceDetails.life_expectancy",
            "mobileDeviceDetails.purchasing_contact"
        },
        tableFieldsUnmapped = {
            "phone_number",
            "wifi_mac_address",
            "model",
            "model_identifier",
            "modelDisplay",
            "model_display",
            "username",
            "mobileDeviceDetails.last_inventory_update",
            "mobileDeviceDetails.last_inventory_update_epoch",
            "mobileDeviceDetails.capacity",
            "mobileDeviceDetails.available",
            "mobileDeviceDetails.initial_entry_date_epoch",
            "mobileDeviceDetails.initial_entry_date_utc",
            "mobileDeviceDetails.modelDisplay",
            "mobileDeviceDetails.model_display",
            "mobileDeviceDetails.last_enrollment_epoch",
            "mobileDeviceDetails.last_cloud_backup_date_epoch",
            "mobileDeviceDetails.location_services_enabled",
            "mobileDeviceDetails.last_backup_time_epoch",
            "mobileDeviceDetails.realname",
            "mobileDeviceDetails.po_date_epoch",
            "mobileDeviceDetails.po_date_utc",
            "mobileDeviceDetails.warranty_expires_epoch",
            "mobileDeviceDetails.warranty_expires_utc",
            "mobileDeviceDetails.lease_expires_epoch",
            "mobileDeviceDetails.lease_expires_utc",
            "mobileDeviceDetails.attachments",
            "mobileDeviceDetails.lost_mode_enforced",
            "mobileDeviceDetails.lost_mode_enable_issued_epoch",
            "mobileDeviceDetails.lost_location_epoch",
            "mobileDeviceDetails.lost_location_latitude",
            "mobileDeviceDetails.lost_location_longitude"
        },
        emptyTable = #table(
            List.Combine(
                {
                    tableFieldsTopLevel,
                    tableFieldsGeneral,
                    tableFieldsHardware,
                    tableFieldsUserAndLocation,
                    tableFieldsSecurity,
                    tableFieldsLostModeLocation,
                    tableFieldsPurchasing,
                    tableFieldsNetwork
                }
            ),
            {}
        ),
        result =
            if totalPagesCount = 0 then
                emptyTable
            else
                let
                    pages = {0..totalPagesCount - 1},
                    listOfPages = List.Transform(
                        pages,
                        each
                            getPageMobileDevices(
                                url, authType, {"GENERAL", "HARDWARE", "USER_AND_LOCATION", "SECURITY", "NETWORK", "PURCHASING"}, _
                            )
                    ),
                    rowPerDevice = List.Combine(listOfPages),
                    selectedColumns = Table.FromRecords(
                        rowPerDevice,
                        {"mobileDeviceId", "deviceType", "general", "hardware", "userAndLocation", "security", "purchasing", "network"},
                        MissingField.UseNull
                    ),
                    renameTopLevelFields = Table.RenameColumns(
                        selectedColumns, List.Zip({apiFieldsTopLevel, tableFieldsTopLevel})
                    ),
                    expandGeneral = Table.ExpandRecordColumn(
                        renameTopLevelFields, "general", apiFieldsGeneral, tableFieldsGeneral
                    ),
                    expandHardware = Table.ExpandRecordColumn(
                        expandGeneral, "hardware", apiFieldsHardware, tableFieldsHardware
                    ),
                    expandUserAndLocation = Table.ExpandRecordColumn(
                        expandHardware, "userAndLocation", apiFieldsUserAndLocation, tableFieldsUserAndLocation
                    ),
                    expandSecurity = Table.ExpandRecordColumn(
                        expandUserAndLocation, "security", apiFieldsSecurity, tableFieldsSecurity
                    ),
                    expandLostModeLocation = Table.ExpandRecordColumn(
                        expandSecurity, "lostModeLocation", apiFieldsLostModeLocation, tableFieldsLostModeLocation
                    ),
                    expandPurchasing = Table.ExpandRecordColumn(
                        expandLostModeLocation, "purchasing", apiFieldsPurchasing, tableFieldsPurchasing
                    ),
                    expandNetwork = Table.ExpandRecordColumn(
                        expandPurchasing, "network", apiFieldsNetwork, tableFieldsNetwork
                    )
                in
                    expandNetwork,
        // duplicate the name column as device_name. we need the same value in both columns for strict backward compatibility
        compatibleDisplayName = Table.AddColumn(result, "device_name", each [name], type text),
        compatibleSerialNumber = Table.AddColumn(
            compatibleDisplayName, "serial_number", each [mobileDeviceDetails.serial_number], type text
        )
    in
        result;

mobileDeviceApplications = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        apiFieldsGeneral = {"displayName", "udid", "managed", "supervised"},
        tableFieldsGeneral = {"name", "udid", "managed", "supervised"},
        apiFieldsHardware = {"serialNumber", "wifiMacAddress", "model", "modelIdentifier"},
        tableFieldsHardware = {"serial_number", "wifi_mac_address", "model", "model_identifier"},
        apiFieldsApps = {"name", "version", "identifier"},
        tableFieldsApps = {
            "mobileDeviceDetails.mdApps.application_name",
            "mobileDeviceDetails.mdApps.application_version",
            "mobileDeviceDetails.mdApps.identifier"
        },
        apiFieldsUserAndLocation = {"phoneNumber", "username"},
        tableFieldsUserAndLocation = {"phone_number", "username"},
        emptyTable = #table(
            List.Combine(
                {{"id"}, tableFieldsGeneral, tableFieldsHardware, tableFieldsUserAndLocation, tableFieldsApps}
            ),
            {}
        ),
        result =
            if totalPagesCount = 0 then
                emptyTable
            else
                let
                    pages = {0..totalPagesCount - 1},
                    listOfPages = List.Transform(
                        pages,
                        each
                            getPageMobileDevices(
                                url, authType, {"GENERAL", "APPLICATIONS", "HARDWARE", "USER_AND_LOCATION"}, _
                            )
                    ),
                    rowPerDevice = List.Combine(listOfPages),
                    selectedColumns = Table.FromRecords(
                        rowPerDevice,
                        {"mobileDeviceId", "general", "hardware", "userAndLocation", "applications"},
                        MissingField.UseNull
                    ),
                    renameIdField = Table.RenameColumns(selectedColumns, {{"mobileDeviceId", "id"}}),
                    expandGeneral = Table.ExpandRecordColumn(
                        renameIdField, "general", apiFieldsGeneral, tableFieldsGeneral
                    ),
                    expandHardware = Table.ExpandRecordColumn(
                        expandGeneral, "hardware", apiFieldsHardware, tableFieldsHardware
                    ),
                    expandUserAndLocation = Table.ExpandRecordColumn(
                        expandHardware, "userAndLocation", apiFieldsUserAndLocation, tableFieldsUserAndLocation
                    ),
                    normalizeApps = Table.ExpandListColumn(expandUserAndLocation, "applications"),
                    expandApps = Table.ExpandRecordColumn(
                        normalizeApps, "applications", apiFieldsApps, tableFieldsApps
                    )
                in
                    expandApps,
        // duplicate the name column as display_name. we need the same value in both columns for strict backward compatibility
        compatibleDisplayName = Table.AddColumn(result, "display_name", each [name], type text),
        // do the same for model, copying it to both modelDisplay and model_display
        compatibleModel_Display = Table.AddColumn(compatibleDisplayName, "model_display", each [model], type text),
        compatibleModelDisplay = Table.AddColumn(compatibleModel_Display, "modelDisplay", each [model], type text)
    in
        compatibleModelDisplay;

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
