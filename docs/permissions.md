# Permissions

What to grant Apple Business and Jamf Pro so Checkpoint can do its work. Grant only what you intend to use: every feature degrades on its own, so a missing privilege disables one thing rather than breaking the app.

For a Platform API connection, permissions work differently — see [Platform API](platform-api.md) instead.

> This page describes the release it ships with. Opening it from a tag shows the permissions that version needs.

## Apple Business

In Apple Business, go to **Settings → Integrations → API** and choose **Add API Account**. Set its **Role Access** to **Device Enrollment Manager** or higher, otherwise it cannot manage device assignments through the API.

Each organization needs its own API account. You need the Client ID, the Key ID, and the downloaded `.pem` private key.

Apple limits an organization to roughly **twenty requests a minute**, and does not signal this with HTTP 429 — past the limit it simply stops completing connections, so failures arrive as network errors. Checkpoint paces itself to stay inside the limit, and reads the whole organization in bulk rather than per device once a lookup exceeds fifteen devices. Nothing needs configuring; it is described here because it explains why a large lookup pauses.

## Jamf Pro

Create an API client under **Settings → API Roles and Clients**, and grant its role the privileges for the features you want.

| Feature | Privilege |
| --- | --- |
| Device lookup, including FileVault state, passcode state and software update status | Read Computers, Read Mobile Devices |
| PreStage display and changes | Read/Update Computer PreStage Enrollments, Read/Update Mobile Device PreStage Enrollments |
| PreStage filtering per ADE token | Read Device Enrollment Program Instances |
| Looking up a group | Read Smart Computer Groups, Read Static Computer Groups, Read Smart Mobile Device Groups, Read Static Mobile Device Groups |
| Site display and changes | Read Sites, Update Computers, Update Mobile Devices |
| Delete records | Delete Computers, Delete Mobile Devices |
| FileVault recovery key | View Disk Encryption Recovery Key |
| Recovery Lock password | View Recovery Lock |
| Device lock PIN | View Computer Device Lock Pin |
| Managed local administrator accounts and passwords | View Local Admin Password |

### MDM commands

Every command needs **View MDM command information in Jamf Pro API**, plus the privilege for that specific command.

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
| Shut Down Device | Send Mobile Device Shut Down Command |
| Update Inventory | Update Inventory for Mobile Devices |
| Renew MDM Profile | Send MDM Check In Command |
| Send Blank Push | Send Declarative Management Command |
| Redeploy Jamf Framework | Send Computer Remote Command to Install Package, Read Computer Check-In |

Shut Down is offered for mobile devices only, because Jamf Pro has no equivalent computer privilege.

Jamf Pro has no single "Read Computer Groups" privilege: smart and static are separate. Checkpoint lists both kinds together, so granting only one half hides the other from the group picker.

Looking up an Apple Business order needs no Jamf Pro privilege and no extra Apple Business role — the order numbers come from the device list Checkpoint already reads. Filtering the results needs nothing at all; it reads what the lookup returned.

### Optional privileges

Without **View Local Admin Password**, the Managed Local Administrator Accounts section is simply absent. Checkpoint reads the accounts during an ordinary lookup, so a missing privilege is treated as "no accounts" rather than an error.

FileVault state comes from the device's inventory record, not from the recovery-key endpoint, so it needs only **Read Computers**. Viewing the key itself still requires **View Disk Encryption Recovery Key**, and still writes an entry to Jamf Pro's own audit trail; simply looking a device up does not.

## Username and password

A username and password connection works too, and takes the privileges of that account. Be aware that an account can hold a valid password and still have no read access, in which case Checkpoint signs in successfully and then finds nothing — the connection test passes because the token was issued. An API client makes the failure explicit, which is why it is the recommended method.
