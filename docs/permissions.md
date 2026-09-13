# Permissions

What to grant Apple Business or Apple School Manager, and Jamf Pro or Jamf School, so Checkpoint can do its work. Grant only what you intend to use: every feature degrades on its own, so a missing privilege disables one thing rather than breaking the app.

For a Platform API connection, permissions work differently — see [Platform API](platform-api.md) instead. The Platform API is Jamf Pro only.

For what each feature actually does, see [Features](features.md).

> This page describes the release it ships with. Opening it from a tag shows the permissions that version needs.

## Apple Business and Apple School Manager

The two are the same API behind different hosts, so most of the setup is identical. In either service, select your name at the bottom of the sidebar, then **Preferences → API → Get Started**. Name the account, create it, and choose **Generate Private Key**: the `.pem` file downloads once and cannot be downloaded again.

They differ in one respect. **Apple Business** asks for a role — set it to **Device Enrollment Manager** or higher, otherwise the account cannot manage device assignments. **Apple School Manager** asks for no role at all; creating the account is enough, and only an Administrator or Site Manager can create one.

Choose the service when adding the organization in Checkpoint: it selects the host and the OAuth scope. Credentials for one will not work against the other — the token request is refused with `invalid_scope`.

**Apple School Manager cannot release devices from the organization.** It defines no such activity, so Checkpoint dims Release for those organizations. Assign, unassign and the three migration actions all work.

Each organization needs its own API account. You need the Client ID, the Key ID, and the downloaded `.pem` private key.

Apple limits an organization to roughly **twenty requests a minute**, and does not signal this with HTTP 429 — past the limit it simply stops completing connections, so failures arrive as network errors. Checkpoint paces itself to stay inside the limit, and reads the whole organization in bulk rather than per device once a lookup exceeds fifteen devices. Nothing needs configuring; it is described here because it explains why a large lookup pauses.

## Jamf School

A different product from Jamf Pro with a much smaller API, so Checkpoint shows less for it. Choose **Jamf School** as the product when adding the server; what it has no source for is hidden rather than shown empty.

Create the key under **Organization → Settings → API → Add API Key**. Authentication is the **Network ID** as the user and the **API key** as the password; the Network ID is under **Devices → Enroll Device(s)**.

Each key carries its own list of permitted methods, chosen when you create it. Grant only what you intend to use: a missing method refuses one feature rather than the connection, and Checkpoint reports it as a missing method rather than as bad credentials.

| Feature | Methods the key needs |
| --- | --- |
| Device lookup, location display, ADE profile, last check-in | Get devices, Get locations |
| Looking up a group | Get device groups, Get devices |
| Passcode state | Get device details |
| Update Inventory | Refresh device inventory |
| Restart Device | Restart device |
| Wipe | Wipe device |
| Remove MDM Profile | Unenroll device |
| Change location | Move devices |
| Move to Trash | Delete device |

**What Jamf School cannot report**, and therefore what Checkpoint leaves out entirely for it: FileVault state, MDM profile expiration, software update state, last enrollment date, last inventory update, sites, PreStage scope, and all four recovery secrets. `hardwareEncryptionEnabled` is not FileVault and is not used.

Three differences worth knowing. There is no computer/mobile split: one device resource serves both, so Wipe and Remove MDM Profile reach a Mac through the same call as an iPad, and Restart is offered for Macs too. **Move to Trash is not Jamf Pro's delete**: the record is recoverable in Jamf School, and the device stops being managed. And **a device with an assigned owner cannot change location** unless the owner is in the district or Cross Location Enrollment is enabled — Jamf School refuses the move, and Checkpoint names the devices it would not move rather than reporting a success.

Location changes are sent twenty devices at a time, which is the API's own limit, so a larger selection is split across several requests.

Timestamps come back in the instance's own time zone with no offset attached. Checkpoint reads the zone from the device record and converts, so a check-in reads correctly wherever you are.

## Jamf Pro

Create an API client under **Settings → API Roles and Clients**, and grant its role the privileges for the features you want.

| Feature | Privilege |
| --- | --- |
| Device lookup, including FileVault state, passcode state and software update state | Read Computers, Read Mobile Devices |
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
| Renew MDM Profile | Send Command to Renew MDM Profile |
| Send Blank Push | Send Declarative Management Command |
| Redeploy Jamf Framework | Send Computer Remote Command to Install Package, Read Computer Check-In |

Shut Down is offered for mobile devices only, because Jamf Pro has no equivalent computer privilege.

Jamf Pro has no single "Read Computer Groups" privilege: smart and static are separate. Checkpoint lists both kinds together, so granting only one half hides the other from the group picker.

Looking up an order needs no Jamf Pro privilege and no extra Apple role — the order numbers come from the device list Checkpoint already reads. Filtering the results needs nothing at all; it reads what the lookup returned.

### Optional privileges

Without **View Local Admin Password**, the Managed Local Administrator Accounts section is simply absent. Checkpoint reads the accounts during an ordinary lookup, so a missing privilege is treated as "no accounts" rather than an error.

Reading the rotation interval, which the confirmation quotes before a password is shown, additionally needs **Read User-Initiated Enrollment** and **Update Local Admin Password Settings** — Jamf Pro guards that setting with an update privilege even for reading it. Without them the confirmation says only that a rotation follows, and the password is still shown.

Software update state comes from the device's own declarative status report and so needs no privilege beyond **Read Computers** and **Read Mobile Devices**. Apple has moved software updates to declarative management, and Jamf Pro's managed software update plans and per-product statuses are both deprecated, so neither is used.

A device that has sent no declarative status report reads "Not reported".

What the row shows is driven by `softwareupdate.install-state`, which Apple defines as the one value that says what the device is doing: `none` means nothing is pending and the last update succeeded. The version, deadline and failure that accompany it are kept by the report long after they stop being true — a Mac that installed an update months ago still carries the version it was offered and the deadline it was given — so they are shown only while an update is actually outstanding. A failure the report still remembers is shown as history, with the date it happened, rather than as a current problem.

FileVault state comes from the device's inventory record, not from the recovery-key endpoint, so it needs only **Read Computers**. Viewing the key itself still requires **View Disk Encryption Recovery Key**, and still writes an entry to Jamf Pro's own audit trail; simply looking a device up does not.

## Username and password

A username and password connection works too, and takes the privileges of that account. Be aware that an account can hold a valid password and still have no read access, in which case Checkpoint signs in successfully and then finds nothing — the connection test passes because the token was issued. An API client makes the failure explicit, which is why it is the recommended method.
