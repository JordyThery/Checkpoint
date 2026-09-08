# Checkpoint

**One list of serial numbers. Both sides of the story.**

Checkpoint is a macOS app for Mac admins that cross-references devices between **Apple Business** and **Jamf Pro**. Instead of switching between two consoles to establish where a device actually stands, you get both perspectives side by side in a single table — and the tools to act on what you find.

Enter serial numbers — typed, pasted, or imported from a text/CSV file — and Checkpoint reports, per device:

**From Apple Business**

- Assignment status (assigned / unassigned / released) and the assigned MDM server
- Warranty and AppleCare coverage
- Model, order number, and purchase source

**From Jamf Pro**

- Whether a device record exists, and its name
- PreStage enrollment scope
- Last enrollment date, last inventory update, Last Contact, and last check-in
- MDM profile expiration

## Beyond reporting

Checkpoint doesn't just surface discrepancies — it resolves them. Every action works on a single device or in bulk across a multi-selection, and always asks for confirmation first:

- **Apple Business**: assign or unassign the MDM server, release a device from the organization
- **Jamf Pro**: change PreStage scope (computers and mobile devices), change the site, delete the device record
- **MDM commands** — computers: Lock, Wipe, Renew MDM Profile, Send Blank Push; mobile devices: Update Inventory, Lock, Restart, Wipe, Send Blank Push, Renew MDM Profile
- Every device links directly to its record in Jamf Pro

Multiple Jamf Pro servers (e.g. production and testing) can be configured and switched from the toolbar.

## Requirements

- macOS 15 or later
- An Apple Business API key (Apple Business → Preferences → API). You need the Client ID, Key ID, and the downloaded `.pem` private key.
- A Jamf Pro server. Both authentication methods are supported:
  - **API client** (recommended): create one under Settings → API Roles and Clients
  - **Username / password** (bearer token)
- Jamf Pro 11.30+ for the Last Contact attribute (older versions simply show "—")

### Jamf Pro API privileges

Grant the API role only what you intend to use:

| Feature | Privilege |
| --- | --- |
| Device lookup | Read Computers, Read Mobile Devices |
| PreStage display & changes | Read/Update Computer PreStage Enrollments, Read/Update Mobile Device PreStage Enrollments |
| PreStage filtering per ADE token | Read Device Enrollment Program Instances |
| Site display & changes | Read Sites, Update Computers, Update Mobile Devices |
| Delete records | Delete Computers, Delete Mobile Devices |
| MDM commands | View MDM command information in Jamf Pro API, plus the per-command send privileges for the commands you use: Send Computer Remote Lock Command, Send Computer Remote Wipe Command, Send Mobile Device Remote Lock Command, Send Mobile Device Remote Wipe Command, Send Mobile Device Remove Passcode Command, Send Mobile Device Restart Device Command, Send Blank Pushes to Mobile Devices, Update Inventory for Mobile Devices |
| Renew MDM Profile | Send MDM Check In Command |

## Security

Credentials are stored only on your Mac: secrets (Apple Business private key, Jamf client secrets/passwords) in the login keychain, non-secret configuration in user defaults. The app is sandboxed and talks exclusively to your configured Jamf Pro servers and Apple's API endpoints (`api-business.apple.com`, `account.apple.com`).

## Building

Open the project in Xcode 26 or later and build the `Checkpoint` scheme (⌘R). No dependencies — the app uses only Apple frameworks.

## Acknowledgements

Inspired by [asbmutil](https://github.com/rodchristiansen/asbmutil) and [AxMJamfSync](https://github.com/karthikeyan-mac/AxMJamfSync).

## Support

If Checkpoint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
