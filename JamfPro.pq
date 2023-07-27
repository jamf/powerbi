[Version = "1.1.0"]
section JamfPro;

[DataSource.Kind="JamfPro", Publish="JamfPro.Publish"]


// gets initial jamf URL from user; uses this to make requests
shared JamfPro.Contents =Value.ReplaceType(
    JamfNavTable,
    type function (
        jamfUrl as (
            type text meta [
                Documentation.FieldCaption = "Jamf Instance URL",
                Documentation.FieldDescription = "The Jamf URL for your specific instance. This is the same one you use to log into your instance.",
                Documentation.FieldSampleValues = {"https://acme.jamfcloud.com"}
            ]
        )
    ) as text);


// sets initial navigation table that links to individual table queries
JamfNavTable = (url as text) as table =>
    let
        url = ValidateUrlScheme(url),
        pages_table = initializeGlobalRecord(url),
        pages_table_mobile = initializeMobileRecord(url),
        mobile_device_groups = initializeMobileGroupRecord(url),
        source = #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, {
            { "Computers", computersImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Attachments", computerAttachmentsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Certificates", computerCertificatesImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Fonts", computerFontsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - iBeacons", computeriBeaconsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Licensed Software", computerLicensedSoftwareImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Local Accounts", computerLocalAccountsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Storage", computerStorageImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Package Receipts", computerPackageReceiptsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Plugins", computerPluginsImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Printers", computerPrintersImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Services", computerServicesImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Software Updates", computerSoftwareUpdatesImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Configuration Profiles", computerConfigurationProfilesImplementation(url, pages_table), "Table", "Table", true},
            { "Computers - Applications", computerApplicationsImplementation(url, pages_table), "Table", "Table", true},
            { "Mobile Devices", mobileDevicesImplementation(url, pages_table_mobile), "Table", "Table", true },
            { "Mobile Devices - Applications", mobileDevicesApplicationsImplementation(url, pages_table_mobile), "Table", "Table", true},
            { "Mobile Devices - Groups", mobileDevicesGroupsImplementation(mobile_device_groups[deviceGroups]), "Table", "Table", true}
            // to-do: add in computer group table/implementation functions
        }),
        navTable = Table.ToNavigationTable(source, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

// simple function to validate that URL is in correct format
ValidateUrlScheme = (url as text) as text => if (Uri.Parts(url)[Scheme] <> "https") then error "Url scheme must be HTTPS" else url;

// initialization functions: 
// these functions set the page tables for the global records
initializeGlobalRecord = (url as text) as table =>
    let
        // number of total devices in computer inventory record
        devices_count = UAPIResource(url, "uapi/v1/computers-inventory")[totalCount],
        pageSize = 100,
        pages = if pageSize <> null then Number.RoundDown(devices_count/pageSize) else Number.RoundDown(devices_count/100),
        page_list = {1..pages},
        pages_table = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table;

initializeMobileRecord = (url as text) as table =>
    let
        devices_count = UAPIResource(url, "uapi/v2/mobile-devices")[totalCount],
        pageSize = 100,
        pages = if pageSize <> null then Number.RoundDown(devices_count/pageSize) else Number.RoundDown(devices_count/100),
        page_list = {1..pages},
        pages_table_mobile = Table.FromList(List.Transform(page_list, Text.From))
    in
        pages_table_mobile;

initializeMobileGroupRecord = (url as text) as table =>
    let 
        jsonDeviceGroups = JSSResource(url, "/mobiledevicegroups"),
        deviceGroups = Table.FromRecords(jsonDeviceGroups[mobile_device_groups]),
        deviceGroupsModified = Table.AddColumn(deviceGroups,"mobileDeviceGroupDetails", each getMobileDeviceGroupDetails([id],url)),
        return_record = Record.Combine({[deviceGroups=deviceGroupsModified]})
    in
        return_record;
// this function acts as our API call for queries
UAPIResource = (baseurl as text, relativepath as text, optional query as record, optional token as text, optional attempts as number) =>
    let 
        number_of_attempts = if attempts = null then 1 else (attempts + 1),
        
        response = if token = null then Web.Contents(baseurl,
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = TokenAuthorizationHeader(baseurl)
            ],
            RelativePath = relativepath,
            ManualStatusHandling = {429, 401},
            IsRetry = attempts <> null,
            Query = query
        ])
        else Web.Contents(baseurl,
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
            @UAPIResource(baseurl, relativepath, query, TokenAuthorizationHeader(baseurl, true), number_of_attempts), #duration(0,0,0,3)
        ) else Json.Document(response)
    in
        json;

// this function is the API call for classic Jamf Pro API data
JSSResource = (baseurl as text, relativepath as text) =>
    let response = Web.Contents(baseurl & "/JSSResource",
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = TokenAuthorizationHeader(baseurl)          
            ],
            RelativePath = relativepath
        ]),
        json = Json.Document(response)
    in
        json;


// gets token for auth header in API call
TokenAuthorizationHeader = (baseurl as text, optional isRetry as logical) =>
    let
        token = Json.Document(Web.Contents(baseurl, [
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


        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
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
                                "enrollmentMethod"
                            }),
        expand_disk_encryption = Table.ExpandRecordColumn(expand_general, "diskEncryption", {"individualRecoveryKeyValidityStatus","institutionalRecoveryKeyPresent","diskEncryptionConfigurationName","fileVault2EligibilityMessage","fileVault2EnabledUserNames","bootPartitionEncryptionDetails"}),
        expand_purchasing = Table.ExpandRecordColumn(expand_disk_encryption, "purchasing", {"purchased","leased","poNumber","lifeExpectancy","purchasePrice","purchasingAccount","purchasingContact","appleCareId","vendor","leaseDate","poDate","warrantyDate"}),
        expand_user_and_location = Table.ExpandRecordColumn(expand_purchasing, "userAndLocation", {"username","realname","email","position","phone","departmentId","buildingId","room"}),
        expand_hardware = Table.ExpandRecordColumn(expand_user_and_location, "hardware", {"make","model","modelIdentifier","serialNumber","processorSpeedMhz","processorCount","coreCount","processorType","processorArchitecture","busSpeedMhz","cacheSizeKilobytes","networkAdapterType","macAddress","altNetworkAdapterType","altMacAddress","totalRamMegabytes","openRamSlots","batteryCapacityPercent","smcVersion","nicSpeed","opticalDrive","bootRom","bleCapable","supportsIosAppInstalls","appleSilicon"}),
        expand_operating_system = Table.ExpandRecordColumn(expand_hardware, "operatingSystem", {"name","version","build","activeDirectoryStatus","fileVault2Status","softwareUpdateDeviceId"}, {"os name","os version","os build","activeDirectoryStatus","fileVault2Status","softwareUpdateDeviceId"})
    in
        expand_operating_system;

computerAttachmentsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Attachments"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "attachments"})
    in
        selected_table;

computerCertificatesImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Certificates"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "certificates"})
    in
        selected_table;

computerFontsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Fonts"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",
        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "fonts"})
    in
        selected_table;

computeriBeaconsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "iBeacons"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "ibeacons"})
    in
        selected_table;

computerLicensedSoftwareImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Licensed_Software"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) -1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "licensedSoftware"})
    in
        selected_table;

computerLocalAccountsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Local_User_Accounts"
        },Text.Upper),

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each  Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) -1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "localUserAccounts"}),
        expand_local_users = Table.ExpandListColumn(selected_table, "localUserAccounts"),
        filtered_table = Table.SelectRows(expand_local_users, each [localUserAccounts] <> null),
        expand_local_user2 = Table.ExpandRecordColumn(filtered_table, "localUserAccounts", {"uid", "username", "fullName", "admin", "userAccountType", "homeDirectory", "homeDirectorySizeMb", "fileVault2Enabled", "passwordMinLength", "passwordMaxAge", "passwordMinComplexCharacters", "passwordRequireAlphanumeric", "passwordHistoryDepth", "computerAzureActiveDirectoryId", "userAzureActiveDirectoryId", "azureActiveDirectoryId"})
    in
        expand_local_user2;

computerStorageImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Storage"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) -1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "storage"})
    in
        selected_table;

computerPackageReceiptsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Package_Receipts"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "packageReceipts"})
    in
        selected_table;

computerPluginsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Plugins"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "plugins"})
    in
        selected_table;

computerPrintersImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Printers"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) -1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "printers"})
    in
        selected_table;

computerServicesImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Services"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "services"})
    in
        selected_table;

computerSoftwareUpdatesImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Software_Updates"
        }, Text.Upper),
        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "softwareUpdates"})
    in
        selected_table;

computerConfigurationProfilesImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Configuration_Profiles"
        }, Text.Upper),

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "configurationProfiles"}),
        expand_profiles = Table.ExpandListColumn(selected_table, "configurationProfiles"),
        filtered_table = Table.SelectRows(expand_profiles, each [configurationProfiles] <> null),
        expand_profiles2 = Table.ExpandRecordColumn(filtered_table, "configurationProfiles", {"id", "username", "lastInstalled", "removable", "displayName", "profileIdentifier"}, {"profileId", "username", "lastInstalled", "removable", "displayName", "profileIdentifier"})
    in
        expand_profiles2;

computerApplicationsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Applications"
        }, Text.Upper),

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v1/computers-inventory", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "applications"}),
        expand_applications = Table.ExpandListColumn(selected_table, "applications"),
        filtered_table = Table.SelectRows(expand_applications, each [applications] <> null),
        expand_applications2 = Table.ExpandRecordColumn(filtered_table, "applications", {"name", "path", "version", "macAppStore", "sizeMegabytes", "bundleId", "updateAvailable", "externalVersionId"})
    in
        expand_applications2;


// start of mobile device queries
mobileDevicesImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "General",
            "Hardware",
            "User_And_Location",
            "Purchasing",
            "Security",
            "Applications",
            "Ebooks",
            "Network",
            "Service_Subscriptions",
            "Certificates",
            "Profiles",
            "User_Profiles",
            "Provisioning_Profiles",
            "Shared_Users"
        }, Text.Upper),

        pageSize = "100",

        updated_page_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v2/mobile-devices/detail", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        mobile_devices_table = Table.Combine(updated_page_table[response]),
        expand_hardware = Table.ExpandRecordColumn(mobile_devices_table,
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
                "deviceId"
            }),
        expand_user_and_location = Table.ExpandRecordColumn(expand_hardware, 
            "userAndLocation", 
            {
                "username",
                "realName",
                "emailAddress",
                "position",
                "phoneNumber",
                "departmentId",
                "buildingId",
                "room",
                "building",
                "department"
            }),
        expand_purchasing = Table.ExpandRecordColumn(expand_user_and_location,
            "purchasing",
            {
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
            }
        ),
        expand_general = Table.ExpandRecordColumn(expand_purchasing,
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
                "airPlayPassword",
                "locales",
                "languages"
            })
    in
        expand_general;

mobileDevicesApplicationsImplementation = (baseurl as text, pages_table as table) as table =>
    let
        sections = List.Transform({
            "Applications"
        }, Text.Upper),

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = "100",

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseurl, "uapi/v2/mobile-devices/detail", [#"page-size" = pageSize, page = Text.From(Number.From(_[Column1]) - 1), section = sections])[results])),
        devices_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(devices_table, {"mobileDeviceId", "applications"}),
        expand_applications = Table.ExpandListColumn(selected_table, "applications"),
        filtered_table = Table.SelectRows(expand_applications, each [applications] <> null),
        expand_applications2 = Table.ExpandRecordColumn(filtered_table, "applications", {"identifier", "name", "version", "shortVersion", "managementStatus", "validationStatus", "bundleSize", "dynamicSize"})
    in
        expand_applications2;

mobileDevicesGroupsImplementation = (deviceGroups as table) as table =>
   let

        temp_table = Table.ExpandRecordColumn(deviceGroups, "mobileDeviceGroupDetails", {"mdgroup"}, {"mobileDeviceGroupDetails.mdgroup"}),
        expanded_table = Table.ExpandListColumn(temp_table, "mobileDeviceGroupDetails.mdgroup"),
        expanded_table_2 = Table.ExpandRecordColumn(expanded_table, "mobileDeviceGroupDetails.mdgroup", {"id", "name", "mac_address", "udid", "wifi_mac_address", "serial_number"}, {"device_id", "device_name", "device_mac_address", "device_udid", "device_wifi_mac_address", "device_serial_number"})
    in
        expanded_table_2;

getMobileDeviceGroupDetails = (id as number, baseurl as text) as any =>
    let 
        jsonMDDetails = getJssResource(id,baseurl,"/mobiledevices/id/"),
        mobile_device = jsonMDDetails[mobile_device],
        general = mobile_device[general],
        location = mobile_device[location], 
        purchasing = mobile_device[purchasing],
        security = mobile_device[security],
        network = mobile_device[network],
        extensionAttributes = mobile_device[extension_attributes],
        extAttrRec = [extAttrs=extensionAttributes],
        applications = mobile_device[applications],
        applicationsRec = [mdApps=applications],
        result = Record.Combine({general,location,purchasing,security,network,extAttrRec,applicationsRec})
    in
        result;

getJssResource = (id as number, baseurl as text,path as text) as any =>
    let
        response = JSSResource(baseurl,path & Number.ToText(id)),
        result = Json.Document(response)
    in
        result;
 
// Data Source Kind description
JamfPro = [
    TestConnection = (dataSourcePath) => {"JamfPro.Contents", dataSourcePath},
    Authentication = [
        UsernamePassword = [
            UsernameLabel="Enter your Jamf Instance User name: ",
            PasswordLabel="Enter your Jamf Instance password: "
        ]
    ],
    Label = Extension.LoadString("JamfPro_URL")
];

// Data Source UI publishing description
JamfPro.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { "Jamf Pro", "Access your organization's JamfPro model" },
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
