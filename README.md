# powerbi
Jamf Power BI Integration - Custom Connector

This custom connector workflow requires Jamf Pro 10.48 or higher.

Refer to the [install guide pdf](./Jamf%20PowerBI%20Basic%20Installation%20Instructions%20for%20PowerBI%20Desktop.pdf)
for installation and conenction settings.

### Developer set-up
VS Code on Windows is the recommended development environment. Note that the Power Query SDK
is required and is only available on Windows. 

1. On Windows, launch Visual Studio Code.
2. Install the Power Query SDK extension from the extensions marketplace.
3. Open the folder `powerbi/JamfPro` in VS Code.
4. Select Setup workspace… from the Power Query SDK tools.
5. Go to Terminal → Run Build Task.

The [`.vscode`](JamfPro/.vscode) directory includes the Power Query project environment settings and a
default build task to assemble a `.mez` file and copy it to the repository's root directory. That resulting
file can be placed in your 'Custom Connector' folder for use in Power BI Desktop.

 ### Branching strategy and contributions
* `main` is protected and reflects the latest published version of the connector.
* `develop` is the default branch for development. Any pull requests should be made against this branch.

### CI
None yet, but a GitHub Action will be added to automate the build process. Until then, keep the `.mez` 
file in the repository root directory up-to-date with any code changes.