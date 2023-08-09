# powerbi
Jamf PowerBI Integration - Custom Connector

This custom connector workflow requires Jamf Pro 10.48 or higher due to how the queries are formed.

Please refer to the "Jamf PowerBI Basic Installation Instructions for PowerBI Desktop.pdf" document for installation and conenction settings.

### Development Set-Up
Please follow the following steps to get your development environment set up in VS Code for contributing to the codebase.  You will need to have the Power Query SDK installed on your machine/VM (only available on Windows).  Please open PRs against Development for consideration.
 - Launch Visual Studio Code
 - Install Power Query SDK extension from the extensions marketplace
 - In VS Code, Open Folder…`powerbi/JamfPro`
 - Select Setup workspace… from Power Query SDK tools
 - Terminal → Run Build Task → Build connector project using MakePQX