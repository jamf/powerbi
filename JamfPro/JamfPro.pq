[Version = "2.0.0"]
section JamfPro;

pageSize = 100;
EnableTraceOutput = true;

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

// Computer lookup and mapping function. See notes on mobileDevices function for backward compatibility.
computers = (url as text, authType as text, totalPagesCount as number) as table =>
    let
        tableFieldsTopLevel = {"id", "computerDetails.udid"},
        emptyTable = #table(
            List.Combine(
                {
                    tableFieldsTopLevel,
                    ComputerMappings[TableGeneral]
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
                        {"id", "udid", "general", "diskEncryption", "purchasing", "userAndLocation", "hardware", "security", "operatingSystem"},
                        MissingField.UseNull
                    ),
                    renameUdid = Table.RenameColumns(selectedColumns, {{"udid", "computerDetails.udid"}}),
                    expandGeneral = Table.ExpandRecordColumn(
                        renameUdid, "general", ComputerMappings[ApiGeneral], ComputerMappings[TableGeneral]
                    ),
                    expandRemoteManagement = Table.ExpandRecordColumn(
                        expandGeneral, "remoteManagement", ComputerMappings[ApiRemoteManagement], ComputerMappings[TableRemoteManagement]
                    ),
                    expandMdmCapable = Table.ExpandRecordColumn(
                        expandRemoteManagement, "mdmCapable", ComputerMappings[ApiMdmCapable], ComputerMappings[TableMdmCapable]
                    ),
                    expandDiskEncryption = Table.ExpandRecordColumn(
                        expandMdmCapable, "diskEncryption", ComputerMappings[ApiDiskEncryption], ComputerMappings[TableDiskEncryption]
                    ),
                    expandPurchasing = Table.ExpandRecordColumn(
                        expandDiskEncryption, "purchasing", ComputerMappings[ApiPurchasing], ComputerMappings[TablePurchasing]
                    ),
                    expandUserAndLocation = Table.ExpandRecordColumn(
                        expandPurchasing, "userAndLocation", ComputerMappings[ApiUserAndLocation], ComputerMappings[TableUserAndLocation]
                    ),
                    expandHardware = Table.ExpandRecordColumn(
                        expandUserAndLocation, "hardware", ComputerMappings[ApiHardware], ComputerMappings[TableHardware]
                    ),
                    expandSecurity = Table.ExpandRecordColumn(
                        expandHardware, "security", ComputerMappings[ApiSecurity], ComputerMappings[TableSecurity]
                    ),
                    expandOperatingSystem = Table.ExpandRecordColumn(
                        expandSecurity, "operatingSystem", ComputerMappings[ApiOperatingSystem], ComputerMappings[TableOperatingSystem]
                    )
                in
                    expandOperatingSystem
    in
        result;

// Mobile device lookup and mapping function.
//
// Notes about backward compatibility with the legacy 1.0.0-beta version of the connector:
// - "API" fields are the fields returned by the Jamf Pro API and "Table" are the fields that will
//   be displayed in the Power BI table. The remapping was necessary to limit the number of
//   changes to the legacy data model, in an effort to preserve existing data sets and
//   visualizations where possible. See FieldMappings.pqm for the full list of mappings.
// - Commented out fields in the API field lists do not have an analogue in the legacy data model
//   and are excluded at this time. They may be added in the future.
// - Fields in the "Unmapped" list will be removed from legacy data models. Most of these are
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
                    MobileDeviceMappings[TableGeneral],
                    MobileDeviceMappings[TableHardware],
                    MobileDeviceMappings[TableUserAndLocation],
                    MobileDeviceMappings[TableSecurity],
                    MobileDeviceMappings[TableLostModeLocation],
                    MobileDeviceMappings[TablePurchasing],
                    MobileDeviceMappings[TableNetwork]
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
                        renameTopLevelFields, "general", MobileDeviceMappings[ApiGeneral], MobileDeviceMappings[TableGeneral]
                    ),
                    expandHardware = Table.ExpandRecordColumn(
                        expandGeneral, "hardware", MobileDeviceMappings[ApiHardware], MobileDeviceMappings[TableHardware]
                    ),
                    expandUserAndLocation = Table.ExpandRecordColumn(
                        expandHardware, "userAndLocation", MobileDeviceMappings[ApiUserAndLocation], MobileDeviceMappings[TableUserAndLocation]
                    ),
                    expandSecurity = Table.ExpandRecordColumn(
                        expandUserAndLocation, "security", MobileDeviceMappings[ApiSecurity], MobileDeviceMappings[TableSecurity]
                    ),
                    expandLostModeLocation = Table.ExpandRecordColumn(
                        expandSecurity, "lostModeLocation", MobileDeviceMappings[ApiLostModeLocation], MobileDeviceMappings[TableLostModeLocation]
                    ),
                    expandPurchasing = Table.ExpandRecordColumn(
                        expandLostModeLocation, "purchasing", MobileDeviceMappings[ApiPurchasing], MobileDeviceMappings[TablePurchasing]
                    ),
                    expandNetwork = Table.ExpandRecordColumn(
                        expandPurchasing, "network", MobileDeviceMappings[ApiNetwork], MobileDeviceMappings[TableNetwork]
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
