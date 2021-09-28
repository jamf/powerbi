[version="1.1.0"]
section JamfPro;

[DataSource.Kind="JamfPro", Publish="JamfPro.Publish"]

/*
This is the shared function which the query calls on

This accepts a URL in the form of text, and asks for the type of UAPI.
*/
shared JamfPro.Contents =Value.ReplaceType(
    JamfNavTable,
    type function (
        jamfUrl as (
            type text meta [
                Documentation.FieldCaption = "Jamf Instance URL",
                Documentation.FieldDescription = "The Jamf URL for your specific instance. This is the same one you use to log into your instance.",
                Documentation.FieldSampleValues = {"https://acme.jamfcloud.com"}]),
        apiType as (
            type text meta [
                Documentation.FieldCaption = "API Type",
                Documentation.FieldDescription = "The type of API to be used.",
                Documentation.AllowedValues = {"Legacy", "UAPI"}])) as text);


/*
This is a function which is just a proxy to the actual nav table being built. This determines if the user wants UAPI or Legacy.

This is called by JamfPro.Contents
*/
JamfNavTable=(jamfUrl as text, apiType as text) as table =>
    let
        source = if apiType = "UAPI" then UAPINavTable(jamfUrl) else LegacyAPINavTable(jamfUrl)
    in
        source;

/*
This function handles the creation of the Nav table using the legacy API. This uses Basic Auth and can be slow for bigger instances.
*/
LegacyAPINavTable = (jamfUrl as text) as table =>
    let
        url = ValidateUrlScheme(jamfUrl),
        temp_table=legacyInitializeGlobalRecord(url),
        temp_mobile_devices=legacyInitializeMobileRecord(url),
        temp_mobile_devices_group=legacyInitializeMobileGroupRecord(url),
        temp_comp_group=legacyInitializeComputerGroupRecord(url),
        source = #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, {
                    { "Computers", legacyComputersImpl(temp_table[computers]), "Table", "Table", true },
                    { "Mobile Devices", MobileDevicesImpl(temp_mobile_devices[mobileDevices]), "Table", "Table", true },
                    { "Computer Device Groups", ComputerGroupsImpl(temp_comp_group[computerGroups]), "Table", "Table", true },
                    { "Mobile Device Groups", MobileDevicesGroupsImpl(temp_mobile_devices_group[deviceGroups]), "Table", "Table", true },
                    {"Mobile Devices - ExtensionAttributes",MdExtensionAttributes(temp_mobile_devices[mobileDevices]),"Table","Table",true},
                    {"Computers - Extension attributes",legacyExtensionAttributes(temp_table[computers]),"Table","Table",true},
                    {"Computers - Applications",legacyComputerApplicationsImpl(temp_table[computerApps]),"Table","Table",true},
                    {"Mobile - Applications1",MobileApplicationsImpl(temp_mobile_devices[mobileDevices]),"Table","Table",true}
        }),
        navTable = Table.ToNavigationTable(source, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        navTable;

/*
This function handles the creation of the Nav table using the UAPI which Jamf is moving to. This uses Basic Auth and Bearer token where possible.

note: This still uses some legacy endpoints. This will be updated as Jamf adds the needed endpoints.
*/
UAPINavTable = (jamfUrl as text) as table =>
    let
        url = ValidateUrlScheme(jamfUrl),
        temp_table = initializeGlobalRecord(jamfUrl),
        temp_mobile_devices = legacyInitializeMobileRecord(url),
        temp_mobile_devices_group = legacyInitializeMobileGroupRecord(url),
        temp_comp_group = legacyInitializeComputerGroupRecord(url),
        source = #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, {
            { "Computers", computersImpl(jamfUrl, temp_table), "Table", "Table", true},
            { "Mobile Devices", MobileDevicesImpl(temp_mobile_devices[mobileDevices]), "Table", "Table", true },
            { "Computer Device Groups", ComputerGroupsImpl(temp_comp_group[computerGroups]), "Table", "Table", true },
            { "Mobile Device Groups", MobileDevicesGroupsImpl(temp_mobile_devices_group[deviceGroups]), "Table", "Table", true },
            {"Mobile Devices - ExtensionAttributes",MdExtensionAttributes(temp_mobile_devices[mobileDevices]),"Table","Table",true},
            {"Computers - Extension attributes",extensionAttributes(url, temp_table),"Table","Table",true},
            {"Computers - Applications",computerApplicationsImpl(url, temp_table),"Table","Table",true},
            {"Computers - Configuration Profiles", computerConfigurationProfilesImpl(url, temp_table), "Table", "Table", true},
            {"Mobile - Applications1",MobileApplicationsImpl(temp_mobile_devices[mobileDevices]),"Table","Table",true}
        }),
        navTable = Table.ToNavigationTable(source, {"Name"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
        
        
    in
        navTable;

/*
This validates if the provided URL is in the correct format.
*/
ValidateUrlScheme = (url as text) as text => if (Uri.Parts(url)[Scheme] <> "https") then error "Url scheme must be HTTPS" else url;


/*
This initializes the table to be used globally for the LegacyAPINavTable.
*/
legacyInitializeGlobalRecord = (url as text) as any =>
let
        response = JSSResource(url, "/computers"),
       jsonComputers=Json.Document(response),
       computers=Table.FromRecords(jsonComputers[computers]),
       computersModified=Table.AddColumn(computers,"computerDetails", each GetComputerDetails([id],url)),
       computerApps=Table.AddColumn(computers,"computerDetails",each GetComputerApps([id],url)),
      return_record=Record.Combine({[computers=computersModified,computerApps=computerApps]})
in
        return_record;

/*
Creates a table of pages to be used as reference for future queries to the /v1/computers-inventory endpoint

note: Uses 100 devices per page as default
*/
initializeGlobalRecord = (url as text) as any =>
    let
        devices = UAPIResource(url, "/v1/computers-inventory?page_size=1")[totalCount],
        // We divide by 100 since the default amount per page is 100
        pageSize = 100,

        // Comment out the logic to grab the full number of devices if your instance is large, and uncomment
        // The specific setting for pages to reduce dev time.
        //pages = if pageSize <> null then Number.RoundDown(devices/pageSize) else Number.RoundDown(devices/100),
        pages = 3,
        page_list = {1..pages},
        // Text.From is used to convert the Numbers to Text for the Table
        table = Table.FromList(List.Transform(page_list, Text.From))
    in
        table;

/*
This uses legacy endpoints to obtain mobile records and returns them.
*/
legacyInitializeMobileRecord = (url as text) as any =>
let
        response = JSSResource(url, "/mobiledevices"),
       jsonDevices=Json.Document(response),
       devices=Table.FromRecords(jsonDevices[mobile_devices]),
       devicesModified=Table.AddColumn(devices,"mobileDeviceDetails", each GetMobileDeviceDetails([id],url)),       
      return_record=Record.Combine({[mobileDevices=devicesModified]})
in
        return_record;

legacyInitializeComputerGroupRecord = (url as text) as any =>
    let
        response = JSSResource(url, "/computergroups"),
       computerGroups=Json.Document(response),
       computerGroupsJson=Table.FromRecords(computerGroups[computer_groups]),
       computerGroupsModified=Table.AddColumn(computerGroupsJson,"computerGroupDetails", each GetComputerGroupDetails([id],url)),
      return_record=Record.Combine({[computerGroups=computerGroupsModified]})

    in
        return_record;

legacyInitializeMobileGroupRecord = (url as text) as any =>
    let
       response = JSSResource(url, "/mobiledevicegroups"),
       jsonDevicesGroups=Json.Document(response),
       deviceGroups=Table.FromRecords(jsonDevicesGroups[mobile_device_groups]),
       deviceGroupsModified=Table.AddColumn(deviceGroups,"mobileDeviceGroupDetails", each GetMobileDeviceGroupDetails([id],url)),
      return_record=Record.Combine({[deviceGroups=deviceGroupsModified]})
    in
        return_record;



GetDevices = (website as text, token as text) =>
    let
        source = Web.Contents(website & "/uapi/settings/obj/building",
        [
            Headers = [#"Authorization" = "jamf-token " & token,
                #"Accepts" = "application/json"]]),
        json = Json.Document(source)
    in
        json;



BasicAuthorizationHeader = () =>
    let
        username = Record.Field(Extension.CurrentCredential(), "Username"),
        password = Record.Field(Extension.CurrentCredential(), "Password"),
        bytes = Text.ToBinary(username & ":" & password),
        credentials = Binary.ToText(bytes, BinaryEncoding.Base64),
        value = "Basic " & credentials
    in
        value;

JSSResource = (baseurl as text, relativepath as text) =>
    let source = Web.Contents(baseurl & "/JSSResource",
        [
            Headers = [
                #"Accept" = "application/json"          
            ],
            RelativePath = relativepath
        ])
    in
        source;

/*
This function accepts a base URL which is the Jamf instance, and uses the relative path for the API endpoint.
Additionally the token can be provided to use that specific one, and the attempts that have been made.

The attempts and token parameters are used by the error handling to attempt again during some unstable
connectivity periods and handle the 401 which might occur if the token becomes invalidated during data retrieval.
*/
UAPIResource = (baseurl as text, relativepath as text,optional token as text, optional attempts as number) =>
    let
        // define possible errors
        num_attempts = if attempts = null then 1 else (attempts + 1),
        errors.badRequest = Record.AddField(Error.Record("Bad Request", "this dataset does not exist.")),
        errors.invalidAccessKey = Record.AddField(Error.Record("Invalid Access Key", "Make sure the provided access key is valid")),
        errors.insufficientPermissions = Record.AddField(Error.Record("Insufficient Permissions", "You don't have permission")),
        errors.resourceNotFound = Record.AddField(Error.Record("Page Does Not Exist", "This dataset does not exist")),
        errors.tooManyRequests = Record.AddField(Error.Record("Too Many Requests", "You're reached your daily limit")),
        errors.backendError = Record.AddField(Error.Record("Server Error", "There is unknown server error")),
        errors.serviceUnavailable = Record.AddField(Error.Record("Service Unavailable", "The server is too busy")),

        // Build an error table
        error_records = {errors.badRequest, errors.invalidAccessKey, errors.insufficientPermissions, errors.resourceNotFound, errors.tooManyRequests, errors.serviceUnavailable},
        errors.table = Table.FromRecords(error_records),

        // get response
        response = if token = null then Web.Contents(baseurl & "/uapi",
        [
            Headers = [
                #"Accept" = "application/json",
                #"Authorization" = TokenAuthorizationHeader(baseurl)
            ],
            RelativePath = relativepath,
            Timeout = Duration.FromText("01:00:00.0"),
            ManualStatusHandling = {429, 401},
            IsRetry = attempts <> null
        ])
        else Web.Contents(baseurl & "/uapi",
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

        // Check to see if we got a response, if we didn't let's request it again
        json = if responseCode <> 200 and num_attempts < 3 then Function.InvokeAfter(() => UAPIResource(baseurl, relativepath, TokenAuthorizationHeader(baseurl, true), num_attempts), #duration(0,0,0,3)) else Json.Document(response)
    in
        json;


/*
This will generate a token bearer header string. This is called upon to geneate a token header, but if
isRetry is passed,it will bypass cached credentials and force a new token to be generated.
*/
TokenAuthorizationHeader = (baseurl as text, optional isRetry as logical) =>
    let
        token = Json.Document(Web.Contents(baseurl, [
            Headers =[],
            RelativePath = "/uapi/auth/tokens",
            // Need to do a POST method
            Content = Text.ToBinary(""),
            IsRetry = if isRetry <> null then isRetry else false
        ]))[token],
        token_header = "Bearer " & token
    in
        token_header;


GetJssResource = (id as number, baseurl as text,path as text) as any =>
    let
        response = JSSResource(baseurl,path & Number.ToText(id)),
        result = Json.Document(response)
        
    in
        result;

GetJssResourceWithSuffix = (id as number, baseurl as text,path as text, suffix as text) as any =>
    let
        response = JSSResource(baseurl,path & Number.ToText(id) & suffix),
        result = Json.Document(response)
        
    in
        result;

GetComputerDetails = (id as number,baseurl as text) as any =>
    let 
       jsonComputerDetails =GetJssResource(id,baseurl,"/computers/id/"),
        computer=jsonComputerDetails[computer],
        general=computer[general],
        location=computer[location], 
        purchasing=computer[purchasing],
        hardware=computer[hardware],
        extensionAttributes=computer[extension_attributes],
        extAttrRec=[extAttrs=extensionAttributes],
        result = Record.Combine({general,location,purchasing,hardware,extAttrRec})
    in
        result;

GetComputerApps = (id as number,baseurl as text) as any =>
    let 
       jsonComputerDetails =GetJssResourceWithSuffix(id,baseurl,"/computers/id/","/subset/software"),
        computer=jsonComputerDetails[computer],
        software=computer[software],
        applications=software[applications],
        computerApps=[computerApplications=applications]

    in
        computerApps;

GetMobileDeviceDetails = (id as number,baseurl as text) as any =>
    let 
        jsonMDDetails = GetJssResource(id,baseurl,"/mobiledevices/id/"),
        mobile_device=jsonMDDetails[mobile_device],
        general=mobile_device[general],
         location=mobile_device[location], 
        purchasing=mobile_device[purchasing],
        security=mobile_device[security],
        network=mobile_device[network],
        extensionAttributes=mobile_device[extension_attributes],
        extAttrRec=[extAttrs=extensionAttributes],
        applications=mobile_device[applications],
        applicationsRec=[mdApps=applications],
        result = Record.Combine({general,location,purchasing,security,network,extAttrRec,applicationsRec})
    in
        result;

GetComputerGroupDetails  = (id as number,baseurl as text) as any =>
    let 
         jsonComputerGroupDetails = GetJssResource(id,baseurl,"/computergroups/id/"),
         compgroup=jsonComputerGroupDetails[computer_group],
        comp_group=compgroup[computers],
        result =[computergroup=comp_group]
    in
        result;

GetMobileDeviceGroupDetails = (id as number,baseurl as text) as any =>
    let 
        jsonMDGroupDetails = GetJssResource(id,baseurl,"/mobiledevicegroups/id/"),
        mdgroup=jsonMDGroupDetails[mobile_device_group],
        md_group=mdgroup[mobile_devices],
        result =[mdgroup=md_group]
    in
        result;

legacyComputerApplicationsImpl = (ComputerApps as table) as table =>
    let
         #"Expanded computerDetails" = Table.ExpandRecordColumn(ComputerApps, "computerDetails", {"computerApplications"}, {"computerDetails.computerApplications"}),
    #"Expanded computerDetails.computerApplications" = Table.ExpandListColumn(#"Expanded computerDetails", "computerDetails.computerApplications"),
    #"Expanded computerDetails.computerApplications1" = Table.ExpandRecordColumn(#"Expanded computerDetails.computerApplications", "computerDetails.computerApplications", {"name", "path", "version"}, {"computerDetails.computerApplications.name", "computerDetails.computerApplications.path", "computerDetails.computerApplications.version"})
in
    #"Expanded computerDetails.computerApplications1";

computerApplicationsImpl = (baseUrl as text, pages_table as table) as table =>
    let
        sections = {
            "Applications"
        },

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = 100,

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "/v1/computers-inventory?page-sze=" & Text.From(pageSize) & "&page=" & Text.From(_[Column1]) & "&section=" & queryString)[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "applications"}),
        expand_applications = Table.ExpandListColumn(selected_table, "applications"),
        filtered_table = Table.SelectRows(expand_applications, each [applications] <> null),
        expand_applications2 = Table.ExpandRecordColumn(filtered_table, "applications", {"name", "path", "version", "macAppStore", "sizeMegabytes", "bundleId", "updateAvailable", "externalVersionId"})
    in
        expand_applications2;

computerConfigurationProfilesImpl = (baseUrl as text, pages_table as table) as table =>
    let
        sections = {
            "Configuration_Profiles"
        },

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = 100,

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "/v1/computers-inventory?page-sze=" & Text.From(pageSize) & "&page=" & Text.From(_[Column1]) & "&section=" & queryString)[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "configurationProfiles"}),
        expand_profiles = Table.ExpandListColumn(selected_table, "configurationProfiles"),
        filtered_table = Table.SelectRows(expand_profiles, each [configurationProfiles] <> null),
        expand_profiles2 = Table.ExpandRecordColumn(filtered_table, "configurationProfiles", {"id", "username", "lastInstalled", "removable", "displayName", "profileIdentifier"}, {"profileId", "username", "lastInstalled", "removable", "displayName", "profileIdentifier"})
    in
        expand_profiles2;


 MobileApplicationsImpl = (MobileApps as table) as table =>
    let
        MobileAppsExt = Table.ExpandRecordColumn(MobileApps, "mobileDeviceDetails", {"mdApps"}, {"mobileDeviceDetails.mdApps"}),
       #"Expanded mobileDeviceDetails.mdApps" = Table.ExpandListColumn(MobileAppsExt, "mobileDeviceDetails.mdApps"),
    #"Expanded mobileDeviceDetails.mdApps1" = Table.ExpandRecordColumn(#"Expanded mobileDeviceDetails.mdApps", "mobileDeviceDetails.mdApps", {"application_name", "application_version", "identifier"}, {"mobileDeviceDetails.mdApps.application_name", "mobileDeviceDetails.mdApps.application_version", "mobileDeviceDetails.mdApps.identifier"})
in
    #"Expanded mobileDeviceDetails.mdApps1";

legacyExtensionAttributes = (computersModified as table) as table =>
    let    

        #"Expanded computerDetails" = Table.ExpandRecordColumn(computersModified, "computerDetails", {"extAttrs"}, {"computerDetails.extAttrs"}),
    #"Expanded computerDetails.extAttrs" = Table.ExpandListColumn(#"Expanded computerDetails", "computerDetails.extAttrs"),
    #"Expanded computerDetails.extAttrs1" = Table.ExpandRecordColumn(#"Expanded computerDetails.extAttrs", "computerDetails.extAttrs", {"id", "name", "type", "value"}, {"computerDetails.extAttrs.id", "computerDetails.extAttrs.name", "computerDetails.extAttrs.type", "computerDetails.extAttrs.value"})
in
    #"Expanded computerDetails.extAttrs1";

extensionAttributes = (baseUrl as text, pages_table as table) as table =>
    let
        sections = {
            "General",
            "Hardware",
            "Operating_System",
            "User_And_Location",
            "Purchasing",
            "Extension_Attributes"
        },

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = 100,

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "/v1/computers-inventory?page-sze=" & Text.From(pageSize) & "&page=" & Text.From(_[Column1]) & "&section=" & queryString)[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "general", "hardware", "operatingSystem", "userAndLocation", "purchasing", "diskEncryption"}),
        general_table = Table.SelectColumns(selected_table, {"id", "general"}),
        general_expanded = Table.ExpandRecordColumn(general_table, "general", {"extensionAttributes"}),
        purchasing_table = Table.SelectColumns(selected_table, {"id", "purchasing"}),
        purchasing_expanded = Table.ExpandRecordColumn(purchasing_table, "purchasing", {"extensionAttributes"}),
        user_and_location_table = Table.SelectColumns(selected_table, {"id", "userAndLocation"}),
        user_and_location_expanded = Table.ExpandRecordColumn(user_and_location_table, "userAndLocation", {"extensionAttributes"}),
        operating_system_table = Table.SelectColumns(selected_table, {"id", "operatingSystem"}),
        operating_system_expanded = Table.ExpandRecordColumn(operating_system_table, "operatingSystem", {"extensionAttributes"}),
        hardware_table = Table.SelectColumns(selected_table, {"id", "hardware"}),
        hardware_expanded = Table.ExpandRecordColumn(hardware_table, "hardware", {"extensionAttributes"}),
        temp_ea_table = Table.SelectColumns(computer_table, {"id", "extensionAttributes"}),
        joined_ea_table = Table.Combine({temp_ea_table, general_expanded, purchasing_expanded, user_and_location_expanded, operating_system_expanded, hardware_expanded}),
        ea_expanded = Table.ExpandListColumn(joined_ea_table, "extensionAttributes"),
        ea_expanded2 = Table.ExpandRecordColumn(ea_expanded, "extensionAttributes", {"definitionId", "name", "description", "values"}, {"definitionId", "name", "description", "value"}),
        ea_transformed = Table.TransformColumns(ea_expanded2, {"value", List.First})
    in
        ea_transformed;

MdExtensionAttributes= (mobileDevices as table) as table =>
let
    extAttrs = Table.ExpandRecordColumn(mobileDevices, "mobileDeviceDetails", {"extAttrs"}, {"mobileDeviceDetails.extAttrs"}),
    #"Expanded mobileDeviceDetails.extAttrs" = Table.ExpandListColumn(extAttrs, "mobileDeviceDetails.extAttrs"),
    #"Expanded mobileDeviceDetails.extAttrs1" = Table.ExpandRecordColumn(#"Expanded mobileDeviceDetails.extAttrs", "mobileDeviceDetails.extAttrs", {"id", "name", "type", "value"}, {"ExtAttrId", "ExtAttrName", "ExtAttrType", "ExtAttrVal"})
in
    #"Expanded mobileDeviceDetails.extAttrs1";

legacyComputersImpl = (basetable as table) as table =>
let     
    #"Expanded computerDetails" = Table.ExpandRecordColumn(basetable, "computerDetails", {"id", "name", "mac_address", "alt_mac_address", "ip_address", "country_name", "last_reported_ip", "serial_number", "udid", "jamf_version", "platform", "barcode_1", "barcode_2", "asset_tag", "remote_management", "mdm_capable", "mdm_capable_users", "management_status", "report_date", "report_date_epoch", "report_date_utc", "last_contact_time", "last_contact_time_epoch", "last_contact_time_utc", "initial_entry_date", "initial_entry_date_epoch", "initial_entry_date_utc", "last_cloud_backup_date_epoch", "last_cloud_backup_date_utc", "last_enrolled_date_epoch", "last_enrolled_date_utc", "distribution_point", "sus", "netboot_server", "site", "itunes_store_account_is_active", "username", "realname", "real_name", "email_address", "position", "phone", "phone_number", "department", "building", "room", "is_purchased", "is_leased", "po_number", "vendor", "applecare_id", "purchase_price", "purchasing_account", "po_date", "po_date_epoch", "po_date_utc", "warranty_expires", "warranty_expires_epoch", "warranty_expires_utc", "lease_expires", "lease_expires_epoch", "lease_expires_utc", "life_expectancy", "purchasing_contact", "os_applecare_id", "os_maintenance_expires", "attachments", "make", "model", "model_identifier", "os_name", "os_version", "os_build", "master_password_set", "active_directory_status", "service_pack", "processor_type", "processor_architecture", "processor_speed", "processor_speed_mhz", "number_processors", "number_cores", "total_ram", "total_ram_mb", "boot_rom", "bus_speed", "bus_speed_mhz", "battery_capacity", "cache_size", "cache_size_kb", "available_ram_slots", "optical_drive", "nic_speed", "smc_version", "ble_capable", "sip_status", "gatekeeper_status", "xprotect_version", "institutional_recovery_key", "disk_encryption_configuration", "filevault2_users", "storage", "mapped_printers"}, {"computerDetails.id", "computerDetails.name", "computerDetails.mac_address", "computerDetails.alt_mac_address", "computerDetails.ip_address", "computerDetails.country_name", "computerDetails.last_reported_ip", "computerDetails.serial_number", "computerDetails.udid", "computerDetails.jamf_version", "computerDetails.platform", "computerDetails.barcode_1", "computerDetails.barcode_2", "computerDetails.asset_tag", "computerDetails.remote_management", "computerDetails.mdm_capable", "computerDetails.mdm_capable_users", "computerDetails.management_status", "computerDetails.report_date", "computerDetails.report_date_epoch", "computerDetails.report_date_utc", "computerDetails.last_contact_time", "computerDetails.last_contact_time_epoch", "computerDetails.last_contact_time_utc", "computerDetails.initial_entry_date", "computerDetails.initial_entry_date_epoch", "computerDetails.initial_entry_date_utc", "computerDetails.last_cloud_backup_date_epoch", "computerDetails.last_cloud_backup_date_utc", "computerDetails.last_enrolled_date_epoch", "computerDetails.last_enrolled_date_utc", "computerDetails.distribution_point", "computerDetails.sus", "computerDetails.netboot_server", "computerDetails.site", "computerDetails.itunes_store_account_is_active", "computerDetails.username", "computerDetails.realname", "computerDetails.real_name", "computerDetails.email_address", "computerDetails.position", "computerDetails.phone", "computerDetails.phone_number", "computerDetails.department", "computerDetails.building", "computerDetails.room", "computerDetails.is_purchased", "computerDetails.is_leased", "computerDetails.po_number", "computerDetails.vendor", "computerDetails.applecare_id", "computerDetails.purchase_price", "computerDetails.purchasing_account", "computerDetails.po_date", "computerDetails.po_date_epoch", "computerDetails.po_date_utc", "computerDetails.warranty_expires", "computerDetails.warranty_expires_epoch", "computerDetails.warranty_expires_utc", "computerDetails.lease_expires", "computerDetails.lease_expires_epoch", "computerDetails.lease_expires_utc", "computerDetails.life_expectancy", "computerDetails.purchasing_contact", "computerDetails.os_applecare_id", "computerDetails.os_maintenance_expires", "computerDetails.attachments", "computerDetails.make", "computerDetails.model", "computerDetails.model_identifier", "computerDetails.os_name", "computerDetails.os_version", "computerDetails.os_build", "computerDetails.master_password_set", "computerDetails.active_directory_status", "computerDetails.service_pack", "computerDetails.processor_type", "computerDetails.processor_architecture", "computerDetails.processor_speed", "computerDetails.processor_speed_mhz", "computerDetails.number_processors", "computerDetails.number_cores", "computerDetails.total_ram", "computerDetails.total_ram_mb", "computerDetails.boot_rom", "computerDetails.bus_speed", "computerDetails.bus_speed_mhz", "computerDetails.battery_capacity", "computerDetails.cache_size", "computerDetails.cache_size_kb", "computerDetails.available_ram_slots", "computerDetails.optical_drive", "computerDetails.nic_speed", "computerDetails.smc_version", "computerDetails.ble_capable", "computerDetails.sip_status", "computerDetails.gatekeeper_status", "computerDetails.xprotect_version", "computerDetails.institutional_recovery_key", "computerDetails.disk_encryption_configuration", "computerDetails.filevault2_users", "computerDetails.storage", "computerDetails.mapped_printers"}),
    #"Removed Columns" = Table.RemoveColumns(#"Expanded computerDetails",{"computerDetails.id", "computerDetails.name"}),
    #"Expanded computerDetails.remote_management" = Table.ExpandRecordColumn(#"Removed Columns", "computerDetails.remote_management", {"managed", "management_username", "management_password_sha256"}, {"computerDetails.remote_management.managed", "computerDetails.remote_management.management_username", "computerDetails.remote_management.management_password_sha256"}),
    #"Expanded computerDetails.mdm_capable_users" = Table.ExpandRecordColumn(#"Expanded computerDetails.remote_management", "computerDetails.mdm_capable_users", {"mdm_capable_user"}, {"computerDetails.mdm_capable_users.mdm_capable_user"}),
    #"Extracted Values" = Table.TransformColumns(#"Expanded computerDetails.mdm_capable_users", {"computerDetails.filevault2_users", each Text.Combine(List.Transform(_, Text.From), ","), type text}),
    computersFinal = Table.RemoveColumns(#"Extracted Values",{"computerDetails.storage"})
in
    computersFinal;

/*
This function accepts a table that has the specific pages to be used to build the table. Expands the needed columns and returns the modified table of computers back.

note: Uses the specific sections of the Jamf Pro UAPI's /v1/computers-inventory to properly grab the needed sections.
*/
computersImpl = (baseUrl as text, pages_table as table) as table =>
    let
        
        sections = {
            "General",
            "Hardware",
            "Operating_System",
            "User_And_Location",
            "Purchasing",
            "Disk_Encryption"
        },

        queryString = Text.Combine(List.Transform(sections, Text.Upper), "&section="),
        pageSize = 100,

        temp_table = Table.AddColumn(pages_table, "response", each Table.FromRecords(UAPIResource(baseUrl, "/v1/computers-inventory?page-sze=" & Text.From(pageSize) & "&page=" & Text.From(_[Column1]) & "&section=" & queryString)[results])),
        computer_table = Table.Combine(temp_table[response]),
        selected_table = Table.SelectColumns(computer_table, {"id", "general", "hardware", "operatingSystem", "userAndLocation", "purchasing", "diskEncryption"}),
        expand_general = Table.ExpandRecordColumn(selected_table, "general", {"name","lastIpAddress","lastReportedIp","jamfBinaryVersion","platform","barcode1","barcode2","assetTag","remoteManagement","supervised","mdmCapable","reportDate","lastContactTime","lastCloudBackupDate","lastEnrolledDate","mdmProfileExpiration","initialEntryDate","distributionPoint","site","itunesStoreAccountActive","enrolledViaAutomatedDeviceEnrollment","userApprovedMdm","enrollmentMethod"}),
        expand_disk_encryption = Table.ExpandRecordColumn(expand_general, "diskEncryption", {"individualRecoveryKeyValidityStatus","institutionalRecoveryKeyPresent","diskEncryptionConfigurationName","fileVault2EligibilityMessage","fileVault2EnabledUserNames","bootPartitionEncryptionDetails"}),
        expand_purchasing = Table.ExpandRecordColumn(expand_disk_encryption, "purchasing", {"purchased","leased","poNumber","lifeExpectancy","purchasePrice","purchasingAccount","purchasingContact","appleCareId","vendor","leaseDate","poDate","warrantyDate"}),
        expand_user_and_location = Table.ExpandRecordColumn(expand_purchasing, "userAndLocation", {"username","realname","email","position","phone","departmentId","buildingId","room"}),
        expand_hardware = Table.ExpandRecordColumn(expand_user_and_location, "hardware", {"make","model","modelIdentifier","serialNumber","processorSpeedMhz","processorCount","coreCount","processorType","processorArchitecture","busSpeedMhz","cacheSizeKilobytes","networkAdapterType","macAddress","altNetworkAdapterType","altMacAddress","totalRamMegabytes","openRamSlots","batteryCapacityPercent","smcVersion","nicSpeed","opticalDrive","bootRom","bleCapable","supportsIosAppInstalls","appleSilicon"}),
        expand_operating_system = Table.ExpandRecordColumn(expand_hardware, "operatingSystem", {"name","version","build","activeDirectoryStatus","fileVault2Status","softwareUpdateDeviceId"}, {"os name","os version","os build","activeDirectoryStatus","fileVault2Status","softwareUpdateDeviceId"})
    in
        expand_operating_system;
       
       
    
  



MobileDevicesImpl = (devicesModified as table) as table =>
let
    #"Expanded mobileDeviceDetails" = Table.ExpandRecordColumn(devicesModified, "mobileDeviceDetails", {"id", "display_name", "device_name", "name", "asset_tag", "last_inventory_update", "last_inventory_update_epoch", "last_inventory_update_utc", "capacity", "capacity_mb", "available", "available_mb", "percentage_used", "os_type", "os_version", "os_build", "serial_number", "udid", "initial_entry_date_epoch", "initial_entry_date_utc", "phone_number", "ip_address", "wifi_mac_address", "bluetooth_mac_address", "modem_firmware", "model", "model_identifier", "model_number", "modelDisplay", "model_display", "device_ownership_level", "last_enrollment_epoch", "last_enrollment_utc", "managed", "supervised", "exchange_activesync_device_identifier", "shared", "tethered", "battery_level", "ble_capable", "device_locator_service_enabled", "do_not_disturb_enabled", "cloud_backup_enabled", "last_cloud_backup_date_epoch", "last_cloud_backup_date_utc", "location_services_enabled", "itunes_store_account_is_active", "last_backup_time_epoch", "last_backup_time_utc", "site", "username", "realname", "real_name", "email_address", "position", "phone", "department", "building", "room", "is_purchased", "is_leased", "po_number", "vendor", "applecare_id", "purchase_price", "purchasing_account", "po_date", "po_date_epoch", "po_date_utc", "warranty_expires", "warranty_expires_epoch", "warranty_expires_utc", "lease_expires", "lease_expires_epoch", "lease_expires_utc", "life_expectancy", "purchasing_contact", "attachments", "data_protection", "block_level_encryption_capable", "file_level_encryption_capable", "passcode_present", "passcode_compliant", "passcode_compliant_with_profile", "passcode_lock_grace_period_enforced", "hardware_encryption", "activation_lock_enabled", "jailbreak_detected", "lost_mode_enabled", "lost_mode_enforced", "lost_mode_enable_issued_epoch", "lost_mode_enable_issued_utc", "lost_mode_message", "lost_mode_phone", "lost_mode_footnote", "lost_location_epoch", "lost_location_utc", "lost_location_latitude", "lost_location_longitude","lost_location_altitude", "lost_location_speed", "lost_location_course", "lost_location_horizontal_accuracy", "lost_location_vertical_accuracy", "home_carrier_network", "cellular_technology", "voice_roaming_enabled", "imei", "iccid", "meid", "current_carrier_network", "carrier_settings_version", "current_mobile_country_code", "current_mobile_network_code", "home_mobile_country_code", "home_mobile_network_code", "data_roaming_enabled", "roaming"}, {"mobileDeviceDetails.id", "mobileDeviceDetails.display_name", "mobileDeviceDetails.device_name", "mobileDeviceDetails.name", "mobileDeviceDetails.asset_tag", "mobileDeviceDetails.last_inventory_update", "mobileDeviceDetails.last_inventory_update_epoch", "mobileDeviceDetails.last_inventory_update_utc", "mobileDeviceDetails.capacity", "mobileDeviceDetails.capacity_mb", "mobileDeviceDetails.available", "mobileDeviceDetails.available_mb", "mobileDeviceDetails.percentage_used", "mobileDeviceDetails.os_type", "mobileDeviceDetails.os_version", "mobileDeviceDetails.os_build", "mobileDeviceDetails.serial_number", "mobileDeviceDetails.udid", "mobileDeviceDetails.initial_entry_date_epoch", "mobileDeviceDetails.initial_entry_date_utc", "mobileDeviceDetails.phone_number", "mobileDeviceDetails.ip_address", "mobileDeviceDetails.wifi_mac_address", "mobileDeviceDetails.bluetooth_mac_address", "mobileDeviceDetails.modem_firmware", "mobileDeviceDetails.model", "mobileDeviceDetails.model_identifier", "mobileDeviceDetails.model_number", "mobileDeviceDetails.modelDisplay", "mobileDeviceDetails.model_display", "mobileDeviceDetails.device_ownership_level", "mobileDeviceDetails.last_enrollment_epoch", "mobileDeviceDetails.last_enrollment_utc", "mobileDeviceDetails.managed", "mobileDeviceDetails.supervised", "mobileDeviceDetails.exchange_activesync_device_identifier", "mobileDeviceDetails.shared", "mobileDeviceDetails.tethered", "mobileDeviceDetails.battery_level", "mobileDeviceDetails.ble_capable", "mobileDeviceDetails.device_locator_service_enabled", "mobileDeviceDetails.do_not_disturb_enabled", "mobileDeviceDetails.cloud_backup_enabled", "mobileDeviceDetails.last_cloud_backup_date_epoch", "mobileDeviceDetails.last_cloud_backup_date_utc", "mobileDeviceDetails.location_services_enabled", "mobileDeviceDetails.itunes_store_account_is_active", "mobileDeviceDetails.last_backup_time_epoch", "mobileDeviceDetails.last_backup_time_utc", "mobileDeviceDetails.site", "mobileDeviceDetails.username", "mobileDeviceDetails.realname", "mobileDeviceDetails.real_name", "mobileDeviceDetails.email_address", "mobileDeviceDetails.position", "mobileDeviceDetails.phone", "mobileDeviceDetails.department", "mobileDeviceDetails.building", "mobileDeviceDetails.room", "mobileDeviceDetails.is_purchased", "mobileDeviceDetails.is_leased", "mobileDeviceDetails.po_number", "mobileDeviceDetails.vendor", "mobileDeviceDetails.applecare_id", "mobileDeviceDetails.purchase_price", "mobileDeviceDetails.purchasing_account", "mobileDeviceDetails.po_date", "mobileDeviceDetails.po_date_epoch", "mobileDeviceDetails.po_date_utc", "mobileDeviceDetails.warranty_expires", "mobileDeviceDetails.warranty_expires_epoch", "mobileDeviceDetails.warranty_expires_utc", "mobileDeviceDetails.lease_expires", "mobileDeviceDetails.lease_expires_epoch", "mobileDeviceDetails.lease_expires_utc", "mobileDeviceDetails.life_expectancy", "mobileDeviceDetails.purchasing_contact", "mobileDeviceDetails.attachments", "mobileDeviceDetails.data_protection", "mobileDeviceDetails.block_level_encryption_capable", "mobileDeviceDetails.file_level_encryption_capable", "mobileDeviceDetails.passcode_present", "mobileDeviceDetails.passcode_compliant", "mobileDeviceDetails.passcode_compliant_with_profile", "mobileDeviceDetails.passcode_lock_grace_period_enforced", "mobileDeviceDetails.hardware_encryption", "mobileDeviceDetails.activation_lock_enabled", "mobileDeviceDetails.jailbreak_detected", "mobileDeviceDetails.lost_mode_enabled", "mobileDeviceDetails.lost_mode_enforced", "mobileDeviceDetails.lost_mode_enable_issued_epoch", "mobileDeviceDetails.lost_mode_enable_issued_utc", "mobileDeviceDetails.lost_mode_message", "mobileDeviceDetails.lost_mode_phone", "mobileDeviceDetails.lost_mode_footnote", "mobileDeviceDetails.lost_location_epoch", "mobileDeviceDetails.lost_location_utc", "mobileDeviceDetails.lost_location_latitude", "mobileDeviceDetails.lost_location_longitude", "mobileDeviceDetails.lost_location_altitude", "mobileDeviceDetails.lost_location_speed", "mobileDeviceDetails.lost_location_course", "mobileDeviceDetails.lost_location_horizontal_accuracy", "mobileDeviceDetails.lost_location_vertical_accuracy", "mobileDeviceDetails.home_carrier_network", "mobileDeviceDetails.cellular_technology", "mobileDeviceDetails.voice_roaming_enabled", "mobileDeviceDetails.imei", "mobileDeviceDetails.iccid", "mobileDeviceDetails.meid", "mobileDeviceDetails.current_carrier_network", "mobileDeviceDetails.carrier_settings_version", "mobileDeviceDetails.current_mobile_country_code", "mobileDeviceDetails.current_mobile_network_code", "mobileDeviceDetails.home_mobile_country_code", "mobileDeviceDetails.home_mobile_network_code", "mobileDeviceDetails.data_roaming_enabled", "mobileDeviceDetails.roaming"}),
    #"Removed Columns" = Table.RemoveColumns(#"Expanded mobileDeviceDetails",{"mobileDeviceDetails.id", "mobileDeviceDetails.display_name", "mobileDeviceDetails.device_name", "mobileDeviceDetails.name"})
in
    #"Removed Columns";
    


MobileDevicesGroupsImpl = (deviceGroups as table) as table =>
   let
       #"Expanded mobileDeviceGroupDetails" = Table.ExpandRecordColumn(deviceGroups, "mobileDeviceGroupDetails", {"mdgroup"}, {"mobileDeviceGroupDetails.mdgroup"}),
    #"Expanded mobileDeviceGroupDetails.mdgroup" = Table.ExpandListColumn(#"Expanded mobileDeviceGroupDetails", "mobileDeviceGroupDetails.mdgroup"),
    #"Expanded mobileDeviceGroupDetails.mdgroup1" = Table.ExpandRecordColumn(#"Expanded mobileDeviceGroupDetails.mdgroup", "mobileDeviceGroupDetails.mdgroup", {"id", "name", "mac_address", "udid", "wifi_mac_address", "serial_number"}, {"device_id", "device_name", "device_mac_address", "device_udid", "device_wifi_mac_address", "device_serial_number"})
in
    #"Expanded mobileDeviceGroupDetails.mdgroup1";
   
ComputerGroupsImpl = (computerGroups as table) as table =>
   let
    #"Expanded computerGroupDetails" = Table.ExpandRecordColumn(computerGroups, "computerGroupDetails", {"computergroup"}, {"computerGroupDetails.computergroup"}),
    #"Expanded computerGroupDetails.computergroup" = Table.ExpandListColumn(#"Expanded computerGroupDetails", "computerGroupDetails.computergroup"),
    #"Expanded computerGroupDetails.computergroup1" = Table.ExpandRecordColumn(#"Expanded computerGroupDetails.computergroup", "computerGroupDetails.computergroup", {"id", "name", "mac_address", "alt_mac_address", "serial_number"}, {"computer_id", "computer_name", "computer_mac_address", "computer_alt_mac_address", "computer_serial_number"}),
    #"Removed Columns" = Table.RemoveColumns(#"Expanded computerGroupDetails.computergroup1",{"computer_mac_address", "computer_alt_mac_address", "computer_serial_number"})
    //#"Renamed Columns" = Table.RenameColumns(#"Removed Columns",{{"computerGroupDetails.computergroup.id", "computer_id"}, {"computerGroupDetails.computergroup.name", "computer_name"}})
in
    #"Removed Columns";


// Data Source Kind description
JamfPro = [
    TestConnection = (dataSourcePath) => {"JamfPro.Contents", dataSourcePath},
    Authentication = [
        
        UsernamePassword = [
             UsernameLabel="Enter your Jamf Instance User name: ",
    PasswordLabel="Enter your Jamf instance password: "
        ]
        
    ],
    
    Label = Extension.LoadString("JamfPro_URL")
];

// Data Source UI publishing description
JamfPro.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = { "Jamf Pro", "Access your organization JamfPro model" },
    LearnMoreUrl = "https://www.jamf.com/",
    SourceImage = JamfPro___Get_Devices.Icons,
    SourceTypeImage = JamfPro___Get_Devices.Icons
];

JamfPro___Get_Devices.Icons = [
    Icon16 = { Extension.Contents("JamfPro16.png"), Extension.Contents("JamfPro20.png"), Extension.Contents("JamfPro24.png"), Extension.Contents("JamfPro32.png") },
    Icon32 = { Extension.Contents("JamfPro32.png"), Extension.Contents("JamfPro40.png"), Extension.Contents("JamfPro48.png"), Extension.Contents("JamfPro64.png") }
];



//
// Common functions
//
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
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;