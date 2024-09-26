[Version = "2.0.0"]
section JamfPro;

// Number of computer or mobile device records to request per page.
PAGE_SIZE = 100;

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
        source = #table(
            {"Name", "Data", "ItemKind", "ItemName", "IsLeaf"},
            {
                {"Computers", computers(url, authType, computerPages), "Table", "Table", true},
                {"Computer Device Groups", computerGroups(url, authType), "Table", "Table", true},
                {"Computers - Applications", computerApplications(url, authType, computerPages), "Table", "Table", true},
                {"Computers - Extension attributes", computerExtensionAttributes(url, authType, computerPages), "Table", "Table", true},
                {"Mobile Devices", mobileDevices(url, authType, mobileDevicesPages), "Table", "Table", true},
                {"Mobile - Applications", mobileDeviceApplications(url, authType, mobileDevicesPages), "Table", "Table", true},
                {"Mobile Device Groups", mobileDeviceGroups(url, authType), "Table", "Table", true},
                {"Mobile Devices - ExtensionAttributes", mobileDeviceExtensionAtttributes(url, authType, mobileDevicesPages), "Table", "Table", true}
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
        totalCount = UAPIResource(
            url, authType, "api/" & relativePath, [#"page-size" = Text.From(PAGE_SIZE)]
        )[totalCount],
        pages = if totalCount = 0 then 0 else Number.RoundUp(totalCount / PAGE_SIZE)
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
                #"page-size" = Text.From(PAGE_SIZE),
                page = Text.From(page),
                section = sections,
                sort = sortKey
            ]
        )[results]
    in
        result;

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
                        pages, each getPageComputers(url, authType, {"GENERAL", "APPLICATIONS"}, _)
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

// Computer lookup and mapping function. See notes on mobileDevices function for backward compatibility.
computers = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        tableFieldsTopLevel = {"id", "computerDetails.udid"},
        emptyTable = #table(
            List.Combine(
                {
                    tableFieldsTopLevel,
                    ComputerMappings[General][mapped]
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
                            getPageComputers(
                                url, authType, {"GENERAL", "DISK_ENCRYPTION", "PURCHASING", "USER_AND_LOCATION", "HARDWARE", "SECURITY", "OPERATING_SYSTEM"}, _
                            )
                    ),
                    rowPerDevice = List.Combine(listOfPages),
                    selectedColumns = Table.FromRecords(
                        rowPerDevice,
                        {"id", "udid", "general", "purchasing", "userAndLocation", "hardware", "security", "operatingSystem"},
                        MissingField.UseNull
                    ),
                    renameUdid = Table.RenameColumns(selectedColumns, {{"udid", "computerDetails.udid"}}),
                    expandGeneral = Table.ExpandRecordColumn(renameUdid, "general", ComputerMappings[General][api], ComputerMappings[General][mapped]),
                    expandRemoteManagement = Table.ExpandRecordColumn(expandGeneral, "remoteManagement", ComputerMappings[RemoteManagement][api], ComputerMappings[RemoteManagement][mapped]),
                    expandMdmCapable = Table.ExpandRecordColumn(expandRemoteManagement, "mdmCapable", ComputerMappings[MdmCapable][api], ComputerMappings[MdmCapable][mapped]),
                    expandPurchasing = Table.ExpandRecordColumn(expandMdmCapable, "purchasing", ComputerMappings[Purchasing][api], ComputerMappings[Purchasing][mapped]),
                    expandUserAndLocation = Table.ExpandRecordColumn(expandPurchasing, "userAndLocation", ComputerMappings[UserAndLocation][api], ComputerMappings[UserAndLocation][mapped]),
                    expandHardware = Table.ExpandRecordColumn(expandUserAndLocation, "hardware", ComputerMappings[Hardware][api], ComputerMappings[Hardware][mapped]),
                    expandSecurity = Table.ExpandRecordColumn(expandHardware, "security", ComputerMappings[Security][api], ComputerMappings[Security][mapped]),
                    expandOperatingSystem = Table.ExpandRecordColumn(expandSecurity, "operatingSystem", ComputerMappings[OperatingSystem][api], ComputerMappings[OperatingSystem][mapped]),

                    expandOperatingSystemWithEpoch = copyUtcColumnsToEpoch(expandOperatingSystem, ComputerMappings[UtcColumnNames])
                in
                    expandOperatingSystemWithEpoch
    in
        result;

// Mobile device lookup and mapping function.
//
// Notes about backward compatibility with the legacy 1.0.0-beta version of the connector:
// - "api" fields are the fields returned by the Jamf Pro API and "mapped" are the fields that will
//   be displayed in the Power BI table. The remapping was necessary to limit the number of
//   changes to the legacy data model, in an effort to preserve existing data sets and
//   visualizations where possible. See MobileDeviceFieldMappings.pqm for the list of mappings.
// - Some fields from the Jamf Pro API do not have an analogue in the legacy data model
//   and are excluded at this time. They may be added in the future.
// - Fields in the "unmapped" list will be removed from legacy data models. Many of these are
//   duplicative (e.g., model/modelDisplay/model_display).
// - Dates are mapped to the _utc variant of the field name to match the legacy data model.
mobileDevices = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        apiFieldsTopLevel = {"mobileDeviceId", "deviceType"},
        tableFieldsTopLevel = {"id", "mobileDeviceDetails.os_type"},

        emptyTable = #table(
            List.Combine(
                {
                    tableFieldsTopLevel,
                    MobileDeviceMappings[General][mapped],
                    MobileDeviceMappings[Hardware][mapped],
                    MobileDeviceMappings[UserAndLocation][mapped],
                    MobileDeviceMappings[Security][mapped],
                    MobileDeviceMappings[LostModeLocation][mapped],
                    MobileDeviceMappings[Purchasing][mapped],
                    MobileDeviceMappings[Network][mapped]
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
                    renameTopLevelFields = Table.RenameColumns(selectedColumns, List.Zip({apiFieldsTopLevel, tableFieldsTopLevel})),
                    expandGeneral = Table.ExpandRecordColumn(renameTopLevelFields, "general", MobileDeviceMappings[General][api], MobileDeviceMappings[General][mapped]),
                    expandHardware = Table.ExpandRecordColumn(expandGeneral, "hardware", MobileDeviceMappings[Hardware][api], MobileDeviceMappings[Hardware][mapped]),
                    expandUserAndLocation = Table.ExpandRecordColumn(expandHardware, "userAndLocation", MobileDeviceMappings[UserAndLocation][api], MobileDeviceMappings[UserAndLocation][mapped]),
                    expandSecurity = Table.ExpandRecordColumn(expandUserAndLocation, "security", MobileDeviceMappings[Security][api], MobileDeviceMappings[Security][mapped]),
                    expandLostModeLocation = Table.ExpandRecordColumn(expandSecurity, "lostModeLocation", MobileDeviceMappings[LostModeLocation][api], MobileDeviceMappings[LostModeLocation][mapped]),
                    expandPurchasing = Table.ExpandRecordColumn(expandLostModeLocation, "purchasing", MobileDeviceMappings[Purchasing][api], MobileDeviceMappings[Purchasing][mapped]),
                    expandNetwork = Table.ExpandRecordColumn(expandPurchasing, "network", MobileDeviceMappings[Network][api], MobileDeviceMappings[Network][mapped])
                in
                    expandNetwork,

        addEpochColumns = copyUtcColumnsToEpoch(result, MobileDeviceMappings[UtcColumnNames]),
        // duplicate the name column as device_name. we need the same value in both columns for strict backward compatibility
        compatibleDisplayName = Table.AddColumn(addEpochColumns, "device_name", each [name], type text),
        compatibleSerialNumber = Table.AddColumn(compatibleDisplayName, "serial_number", each [mobileDeviceDetails.serial_number], type text)
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

computerExtensionAttributes = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        fieldNamesForTable = {"computerDetails.extAttrs.id", "computerDetails.extAttrs.name", "computerDetails.extAttrs.type", "computerDetails.extAttrs.value"} ,
        emptyTable = #table(List.Combine({{"id", "name"}, fieldNamesForTable}), {}),
        result =
            if totalPagesCount = 0 then
                emptyTable
            else
                let
                    pages = {0..totalPagesCount - 1},
                    listOfPages = List.Transform(
                        pages, each getPageComputers(
                            url, authType, {"GENERAL", "HARDWARE", "USER_AND_LOCATION", "PURCHASING", "OPERATING_SYSTEM", "EXTENSION_ATTRIBUTES"}, _
                        )
                    ),
                    rowPerComputer = List.Combine(listOfPages),
                    data = Table.FromRecords(rowPerComputer),
                    selectedColumns = Table.SelectColumns(data, {"id", "general", "hardware", "userAndLocation", "purchasing", "operatingSystem", "extensionAttributes"}),

                    expandGeneral = Table.ExpandRecordColumn(selectedColumns, "general", {"name", "extensionAttributes"}, {"name", "general.extensionAttributes"}),
                    expandHardware = Table.ExpandRecordColumn(expandGeneral, "hardware", {"extensionAttributes"}, {"hardware.extensionAttributes"}),
                    expandUserAndLocation = Table.ExpandRecordColumn(expandHardware, "userAndLocation", {"extensionAttributes"}, {"userAndLocation.extensionAttributes"}),
                    expandPurchasing = Table.ExpandRecordColumn(expandUserAndLocation, "purchasing", {"extensionAttributes"}, {"purchasing.extensionAttributes"}),
                    expandOperatingSystem = Table.ExpandRecordColumn(expandPurchasing, "operatingSystem", {"extensionAttributes"}, {"operatingSystem.extensionAttributes"}),

                    eaApiFields = [id = "definitionId", name = "name", dataType = "dataType", value = "values"],
                    eaTableFields = [id = "computerDetails.extAttrs.id", name = "computerDetails.extAttrs.name", dataType = "computerDetails.extAttrs.type", value = "computerDetails.extAttrs.value"],
                    generalNormalized = normalizeEAs(expandOperatingSystem, "general.extensionAttributes", eaApiFields, eaTableFields),
                    hardwareNormalized = normalizeEAs(expandOperatingSystem, "hardware.extensionAttributes", eaApiFields, eaTableFields),
                    userAndLocationNormalized = normalizeEAs(expandOperatingSystem, "userAndLocation.extensionAttributes", eaApiFields, eaTableFields),
                    purchasingNormalized = normalizeEAs(expandOperatingSystem, "purchasing.extensionAttributes", eaApiFields, eaTableFields),
                    operatingSystemNormalized = normalizeEAs(expandOperatingSystem, "operatingSystem.extensionAttributes", eaApiFields, eaTableFields),
                    extensionAttributesNormalized = normalizeEAs(expandOperatingSystem, "extensionAttributes", eaApiFields, eaTableFields),
                    combinedEAs = Table.Combine({generalNormalized, hardwareNormalized, userAndLocationNormalized, purchasingNormalized, operatingSystemNormalized, extensionAttributesNormalized}),

                    finalColumns = Table.SelectColumns(combinedEAs, List.Combine({{"id", "name"}, fieldNamesForTable}))
                in
                    finalColumns
    in
        result;

mobileDeviceExtensionAtttributes = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        apiFieldsGeneral = {"displayName", "udid", "managed", "supervised", "extensionAttributes"},
        tableFieldsGeneral = {"name", "udid", "managed", "supervised", "general.extensionAttributes"},
        apiFieldsHardware = {"serialNumber", "wifiMacAddress", "model", "modelIdentifier", "extensionAttributes"},
        tableFieldsHardware = {"serial_number", "wifi_mac_address", "model", "model_identifier", "hardware.extensionAttributes"},
        apiFieldsUserAndLocation = {"phoneNumber", "username", "extensionAttributes"},
        tableFieldsUserAndLocation = {"phone_number", "username", "userAndLocation.extensionAttributes"},

        // final column names, including tableFieldsGeneral, tableFieldsHardware, and tableFieldsUserAndLocation, minus anything with `extensionAttributes` in it
        eaFieldNames = {"ExtAttrId", "ExtAttrName", "ExtAttrType", "ExtAttrVal"},
        finalColumnNames = List.Combine(
            {
                {"id"},
                List.RemoveItems(tableFieldsGeneral, {"general.extensionAttributes"}),
                List.RemoveItems(tableFieldsHardware, {"hardware.extensionAttributes"}),
                List.RemoveItems(tableFieldsUserAndLocation, {"userAndLocation.extensionAttributes"}),
                eaFieldNames
            }
        ),

        emptyTable = #table(
            finalColumnNames,
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
                                url, authType, {"GENERAL", "HARDWARE", "USER_AND_LOCATION", "PURCHASING", "EXTENSION_ATTRIBUTES"}, _
                            )
                    ),
                    rowPerDevice = List.Combine(listOfPages),
                    selectedColumns = Table.FromRecords(
                        rowPerDevice,
                        {"mobileDeviceId", "general", "hardware", "userAndLocation", "purchasing", "extensionAttributes"},
                        MissingField.UseNull
                    ),
                    renameIdField = Table.RenameColumns(selectedColumns, {{"mobileDeviceId", "id"}}),
                    expandGeneral = Table.ExpandRecordColumn(renameIdField, "general", apiFieldsGeneral, tableFieldsGeneral),
                    expandHardware = Table.ExpandRecordColumn(expandGeneral, "hardware", apiFieldsHardware, tableFieldsHardware),
                    expandUserAndLocation = Table.ExpandRecordColumn(expandHardware, "userAndLocation", apiFieldsUserAndLocation, tableFieldsUserAndLocation),
                    expandPurchasing = Table.ExpandRecordColumn(expandUserAndLocation, "purchasing", {"extensionAttributes"}, {"purchasing.extensionAttributes"}),

                    eaApiFields = [id = "id", name = "name", dataType = "type", value = "value"],
                    eaTableFields = [id = "ExtAttrId", name = "ExtAttrName", dataType = "ExtAttrType", value = "ExtAttrVal"],
                    generalNormalized = normalizeEAs(expandPurchasing, "general.extensionAttributes", eaApiFields, eaTableFields),
                    userAndLocationNormalized = normalizeEAs(expandPurchasing, "userAndLocation.extensionAttributes", eaApiFields, eaTableFields),
                    hardwareNormalized = normalizeEAs(expandPurchasing, "hardware.extensionAttributes", eaApiFields, eaTableFields),
                    purchasingNormalized = normalizeEAs(expandPurchasing, "purchasing.extensionAttributes", eaApiFields, eaTableFields),
                    extensionAttributesNormalized = normalizeEAs(expandPurchasing, "extensionAttributes", eaApiFields, eaTableFields),
                    combinedEAs = Table.Combine({generalNormalized, userAndLocationNormalized, hardwareNormalized, purchasingNormalized, extensionAttributesNormalized})
                in
                    combinedEAs,

        finalColumns = Table.SelectColumns(result, finalColumnNames),

        // duplicate the name column as display_name. we need the same value in both columns for strict backward compatibility
        compatibleDisplayName = Table.AddColumn(finalColumns, "display_name", each [name], type text),
        // do the same for model, copying it to both modelDisplay and model_display
        compatibleModel_Display = Table.AddColumn(compatibleDisplayName, "model_display", each [model], type text),
        compatibleModelDisplay = Table.AddColumn(compatibleModel_Display, "modelDisplay", each [model], type text)
    in
        compatibleModelDisplay;

normalizeEAs = (t as table, columnName as text, apiFields as record, tableFields as record) as table =>
    let
        normalizeEAs = Table.ExpandListColumn(t, columnName),
        expandEAs = Table.ExpandRecordColumn(
            normalizeEAs, columnName, {apiFields[id], apiFields[name], apiFields[dataType], apiFields[value]}, {tableFields[id], tableFields[name], tableFields[dataType], tableFields[value]}
        ),
        expandValues = Table.ExpandListColumn(expandEAs, tableFields[value]),
        filteredEAs = Table.SelectRows(expandValues, each Record.Field(_, tableFields[id]) <> null),
        result = Table.RemoveColumns(filteredEAs, {columnName}, MissingField.Ignore)
    in
        result;

dateString8600ToEpochMillis = (dateString as text) as number =>
    let
        dateObject = DateTime.FromText(dateString),
        epochMillis = Duration.TotalSeconds(Duration.From(dateObject - #datetime(1970, 1, 1, 0, 0, 0))) * 1000
    in
        epochMillis;

copyUtcColumnsToEpoch = (t as table, utcColumnNames as list) as table =>
    let
        // Generate new column names by replacing "_utc" with "_epoch"
        epochColumnNames = List.Transform(utcColumnNames, each Text.Replace(_, "_utc", "_epoch")),
        
        // Convert each UTC column to epoch milliseconds and add as a new column
        addEpochColumns = List.Accumulate(
            List.Zip({utcColumnNames, epochColumnNames}),
            t,
            (state, current) =>
                let
                    utcColumnName = current{0},
                    epochColumnName = current{1},
                    addColumn = Table.AddColumn(state, epochColumnName, each try dateString8600ToEpochMillis(Record.Field(_, utcColumnName)) otherwise 0, type number)
                in
                    addColumn
        )
    in
        addEpochColumns;

// Data Source definition
JamfPro = [
    TestConnection = (dataSourcePath) => 
        try // try to parse as the current format with jamfUrl and authType
            let
                json = Json.Document(dataSourcePath),
                jamfUrl = json[jamfUrl],
                authType = if Record.HasFields(json, "authType") then json[authType] else "UsernamePassword"
            in
                {"JamfPro.JamfNavTable", jamfUrl, authType}
        otherwise // fallback to the old format from 1.0.0-beta, using the dataSourcePath as the URL
            {"JamfPro.JamfNavTable", dataSourcePath},
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
    Beta = false,
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

Extension.LoadFunction = (fileName as text) =>
  let
      binary = Extension.Contents(fileName),
      asText = Text.FromBinary(binary)
  in
      try
        Expression.Evaluate(asText, #shared)
      catch (e) =>
        error [
            Reason = "Extension.LoadFunction Failure",
            Message.Format = "Loading '#{0}' failed - '#{1}': '#{2}'",
            Message.Parameters = {fileName, e[Reason], e[Message]},
            Detail = [File = fileName, Error = e]
        ];

MobileDeviceMappings = Extension.LoadFunction("MobileDeviceMappings.pqm");
ComputerMappings = Extension.LoadFunction("ComputerMappings.pqm");
