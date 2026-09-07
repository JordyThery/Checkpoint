# Checkpoint

A macOS app for Mac admins that shows the full lifecycle status of Apple devices across **Apple Business Manager** and **Jamf Pro** in one table — and lets you act on it.

Feed it serial numbers (typed, pasted, or imported from a text/CSV file) and Checkpoint shows, per device:

| Source | Information |
| --- | --- |
| Apple Business Manager | Assignment status (assigned / unassigned / released), assigned MDM server, warranty & AppleCare coverage, model, order and purchase source |
| Jamf Pro | Device record & name, PreStage scope, last enrollment date, last inventory update, Last Contact, last check-in, MDM profile expiration |

## Actions

All actions work on a single device or in bulk on a multi-selection, and always ask for confirmation:

- **Apple Business Manager**: assign / unassign MDM server, release from the organization
- **Jamf Pro**: change PreStage scope (computers and mobile devices), delete the device record
- **MDM commands** — computers: Lock, Wipe, Renew MDM Profile, Send Blank Push; mobile devices: Update Inventory, Lock, Clear Passcode, Restart, Wipe, Send Blank Push, Renew MDM Profile
- Every device links directly to its record in Jamf Pro

Multiple Jamf Pro servers (e.g. production and testing) can be configured and switched from the toolbar.

## Requirements

- macOS 15 or later
- An Apple Business Manager API key (ABM → Preferences → API). You need the Client ID, Key ID, and the downloaded `.pem` private key.
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
| Delete records | Delete Computers, Delete Mobile Devices |
| MDM commands | Send Computer Remote Lock Command, Send Computer Remote Wipe Command, Send Blank Pushes to Computers, Send Mobile Device Remote Command, and related command privileges |
| Renew MDM Profile | Send MDM Check In Command |

## Security

Credentials are stored only on your Mac: secrets (ABM private key, Jamf client secrets/passwords) in the login keychain, non-secret configuration in user defaults. The app is sandboxed and talks exclusively to your configured Jamf Pro servers and Apple's API endpoints (`api-business.apple.com`, `account.apple.com`).

## Building

Open the project in Xcode 26 or later and build the `Checkpoint` scheme (⌘R). No dependencies — the app uses only Apple frameworks.

## Acknowledgements

Inspired by [asbmutil](https://github.com/rodchristiansen/asbmutil) and [AxMJamfSync](https://github.com/karthikeyan-mac/AxMJamfSync).

## License

[MIT](LICENSE)
