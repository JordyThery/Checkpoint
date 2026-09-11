<p align="center">
  <img src="docs/icon.png" width="128" alt="Checkpoint app icon">
</p>

# Checkpoint

**One list of serial numbers. Both sides of the story.**

Checkpoint is a macOS app for Mac admins that cross-references devices between **Apple Business** and **Jamf Pro**. Instead of switching between two consoles to establish where a device actually stands, you get both perspectives side by side in a single table, and the tools to act on what you find.

Enter serial numbers, typed, pasted, or imported from a text/CSV file, and Checkpoint reports, per device:

**From Apple Business**

- Assignment status (assigned / unassigned / released) and the assigned MDM server
- MDM server migration status and deadline
- Warranty and AppleCare coverage
- Model, order number, and purchase source

**From Jamf Pro**

- Whether a device record exists, and its name
- PreStage enrollment scope and site
- Last enrollment date, last inventory update, Last Contact, and last check-in
- MDM profile expiration

![Checkpoint showing a Mac and an iPad with their Apple Business and Jamf Pro status side by side, with the bulk actions inspector open](docs/screenshot.png)

## Beyond reporting

Checkpoint doesn't just surface discrepancies, it resolves them. Every action works on a single device or in bulk across a multi-selection, and always asks for confirmation first:

- **Apple Business**: assign or unassign the MDM server, schedule a migration to another MDM server with a deadline (then update or cancel it), release a device from the organization
- **Jamf Pro**: change PreStage scope (computers and mobile devices), change the site, delete the device record
- **MDM commands**, computers: Lock, Wipe, Remove MDM Profile, Renew MDM Profile, Redeploy Jamf Framework, Send Blank Push; mobile devices: Update Inventory, Lock, Clear Passcode, Restart, Wipe, Remove MDM Profile, Send Blank Push, Renew MDM Profile
- Every device links directly to its record in Jamf Pro

Multiple Apple Business organizations and multiple Jamf Pro servers (e.g. production and testing) can be configured and switched from the toolbar.

### MDM server migration

Assigning a device to a different MDM server normally takes effect on the next wipe or enrollment. Apple Business can instead schedule a *migration*: the device keeps running under its current service until it moves, nothing is erased, and Apple prompts the user and enforces the deadline on-device. Checkpoint shows the migration status and deadline for each device, and can schedule, reschedule or cancel one, individually or in bulk. Deadlines cannot be more than 90 days out, and shortening a deadline (or setting one in the past) applies immediately without giving the user a chance to delay.

Migration requires an Apple Business tenant on a release that supports it. Devices Apple reports as not migration-capable are skipped, and the option only appears when a device is eligible.

### Recovery secrets

For Macs, Checkpoint can show the **FileVault personal recovery key**, the **Recovery Lock password**, and the **device lock PIN** from Jamf Pro. Unlike the actions above these are single-device only, are not part of a lookup, and are fetched only when you ask for one. The value appears in a sheet for as long as it is open and is never written to the table, kept on the device record, or included in an export.

## Requirements

- macOS 15 or later
- An Apple Business API account per organization (Apple Business → Settings → Integrations → API). You need the Client ID, Key ID, and the downloaded `.pem` private key.
- A Jamf Pro server. Three connection methods are supported:
  - **API client** (recommended): create one under Settings → API Roles and Clients
  - **Username / password** (bearer token)
  - **Platform API**: an integration in Jamf Account, routed through Jamf's Platform API gateway
- Jamf Pro 11.30+ for the Last Contact attribute (older versions simply show "—")

### Apple Business API access

In Apple Business, go to Settings → Integrations → API and choose **Add API Account**. Set its **Role Access** to **Device Enrollment Manager** or higher, otherwise it cannot manage device assignments through the API. Each organization needs its own API account.

### Jamf Pro API privileges

Grant the API role only what you intend to use:

| Feature | Privilege |
| --- | --- |
| Device lookup | Read Computers, Read Mobile Devices |
| PreStage display and changes | Read/Update Computer PreStage Enrollments, Read/Update Mobile Device PreStage Enrollments |
| PreStage filtering per ADE token | Read Device Enrollment Program Instances |
| Site display and changes | Read Sites, Update Computers, Update Mobile Devices |
| Delete records | Delete Computers, Delete Mobile Devices |
| FileVault recovery key | View Disk Encryption Recovery Key |
| Recovery Lock password | View Recovery Lock |
| Device lock PIN | View Computer Device Lock Pin |

#### MDM commands

Every command needs **View MDM command information in Jamf Pro API**, plus the privilege for that specific command:

| Command | Privilege |
| --- | --- |
| Lock Computer | Send Computer Remote Lock Command |
| Wipe Computer | Send Computer Remote Wipe Command |
| Remove MDM Profile (Mac) | Send Computer Unmanage Command |
| Lock Device | Send Mobile Device Remote Lock Command |
| Wipe Device | Send Mobile Device Remote Wipe Command |
| Remove MDM Profile (mobile) | Unmanage Mobile Devices |
| Clear Passcode | Send Mobile Device Remove Passcode Command |
| Restart Device | Send Mobile Device Restart Device Command |
| Update Inventory | Update Inventory for Mobile Devices |
| Renew MDM Profile | Send MDM Check In Command |
| Send Blank Push | Send Declarative Management Command |
| Redeploy Jamf Framework | Send Computer Remote Command to Install Package, Read Computer Check-In |

### Platform API (optional)

Checkpoint can talk to Jamf Pro through Jamf's [Platform API gateway](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api) instead of connecting to the server directly. Create an integration in **Jamf Account**, then in Checkpoint choose the **Platform API** method and supply the client ID, client secret, gateway region, and tenant ID. The tenant ID is on the tenant pill in the integration's **Integration details** panel.

A Jamf Pro API client will not work here, and the region must match your tenant because gateway tokens are region-locked. The Jamf Pro URL is still required, because device rows link to their records in the Jamf Pro web interface and the gateway host cannot serve those.

Permissions are granted per capability on the integration rather than per privilege:

| Feature | Capability |
| --- | --- |
| Device lookup | Inventory: Read |
| Delete device record | Inventory: Delete |
| Site display and changes | Organizational context: Read, Inventory: Update |
| PreStage display and changes, ADE instances | Enrollment: Read, Enrollment: Update |
| MDM commands | Device actions: Execute |
| Wipe and Remove MDM Profile | Destructive device actions: Execute |
| FileVault recovery key, Recovery Lock password, device lock PIN | Device secrets: Read |

**Not all commands are available over the Platform API.** Jamf does not expose Jamf Pro's batched MDM command endpoint through the gateway, and **Lock, Clear Passcode and Restart** exist only as command types on it, so those cannot be sent. Checkpoint dims them and explains why. Everything else works normally, including Wipe and Remove MDM Profile, which have dedicated per-device endpoints the gateway does expose. Use an API client connection when you need the full command set.

## Security

Credentials are stored only on your Mac: secrets (Apple Business private key, Jamf client secrets/passwords) in the keychain, non-secret configuration in user defaults. The app is sandboxed, so both live in its own container and are not readable by other apps, and it talks exclusively to your configured Jamf Pro servers and Apple's API endpoints.

FileVault recovery keys and Recovery Lock passwords are never stored. They are requested from Jamf Pro one device at a time, held only while the sheet showing them is open, and discarded when it closes.

## Building

Open the project in Xcode 26 or later and build the `Checkpoint` scheme (⌘R). No dependencies, the app uses only Apple frameworks.

## Acknowledgements

Inspired by [asbmutil](https://github.com/rodchristiansen/asbmutil), [AxMJamfSync](https://github.com/karthikeyan-mac/AxMJamfSync), amongst many others.

## Support

If Checkpoint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
