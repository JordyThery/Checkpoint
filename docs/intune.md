# Intune

> See [Permissions](permissions.md) for the Apple side and the Jamf products, and [Features](features.md) for what each feature does.

Checkpoint can cross-reference Apple Business or Apple School Manager against a **Microsoft Intune** tenant instead of a Jamf server. The Apple side is unchanged; only the device management side differs.

> This page describes the release it ships with. Opening it from a tag shows that version.

## Setting one up

Intune is reached through Microsoft Graph with an **Entra app registration**, so the app acts as itself rather than as a signed-in administrator. There is no URL to configure: requests always go to `graph.microsoft.com`.

1. In the Entra admin centre, register an application.
2. Add a **client secret** and copy its value — Entra shows it once.
3. Under **API permissions → Microsoft Graph → Application permissions**, add the permissions below, then **grant admin consent**. Application permissions do nothing until consented.
4. In Checkpoint, add a connection, choose **Intune**, and supply the tenant ID, the client ID and the secret, then use Test Connection.

The tenant ID may be the GUID or a verified domain name; Microsoft accepts either in the token URL.

## Permissions

| Permission | Needed for |
| --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Looking devices up. Without it no device appears at all |
| `DeviceManagementManagedDevices.ReadWrite.All` | Deleting a device record |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Every MDM command, including the harmless ones |

That last grouping is Microsoft's, not a choice Checkpoint makes: Graph documents Restart and Sync under the same privileged permission as Wipe, because the criterion is whether the request reaches the device rather than how much damage it does. Grant only `Read.All` if you want lookups and nothing else — every command will then fail with HTTP 403, naming the permission it wanted.

A missing or unconsented permission reads as HTTP 403, and an expired client secret as HTTP 401. Checkpoint says which of the two it was, since the remedies are entirely different.

## How the tenant is read

Graph documents `$filter` support property by property, and `serialNumber` is not among the properties that accept it. There is therefore no per-serial query to make: Checkpoint reads the tenant once per lookup, a thousand devices per page, and matches serials locally. This is the same shape the Jamf School integration takes, for a different reason.

Devices with no serial number are skipped. Intune reports an empty one for some virtual and personally-enrolled devices, and Checkpoint is keyed on serial numbers throughout.

Each request asks for the fields Checkpoint shows by name. A full `managedDevice` carries over sixty properties including a large Windows health-attestation object, so this keeps a fleet read small and the [activity log](features.md#activity-log) readable.

Graph throttles per application per tenant. A throttled request is retried after the delay Microsoft asks for, up to three times.

## What maps, and what does not

| Reported | Notes |
| --- | --- |
| Record and device name | |
| Installed OS version | With the platform name, as Jamf School reports it. Intune publishes no build number |
| Enrollment date, last sync | One sync time replaces Jamf's four dates, so the inventory and check-in columns are hidden rather than shown empty |
| Management certificate expiration | Fills the MDM profile expiration column, and the expired-profile filter works on it |
| Encryption state | `isEncrypted` is a bare boolean with no partition state or key validity to qualify it. On a computer it fills the FileVault row; on any non-Apple mobile platform it is shown as Encryption |
| Passcode state | Derived: iPhone and iPad enable data protection exactly when a passcode is set, and `isEncrypted` reports data protection there, so it fills the same Passcode row and filter the Jamf products fill |
| Supervised and managed state | Managed is derived from the management channel, which clears when a device is retired |
| Compliance state | Evaluated by Intune and reported with every device. Jamf Pro can also report compliance, but only by relaying a vendor's verdict one device at a time — see [Features](features.md#device-compliance) |

**Not reported.** Sites, PreStage scope, software update state and declarations, and the recovery secrets. Software update state exists only as a tenant-wide report export rather than per device. A FileVault recovery key is available, but only from Graph's beta endpoint, so it is left out until it is not.

**The enrollment profile is not shown either**, and that one is worth explaining. Graph's `enrollmentProfileName` reports the profile a device *enrolled with*, which is not the profile the console shows as *assigned* to it: a Mac that enrolled before its ADE profile existed reports nothing while the console names one. Showing that as "None" would contradict the console, and the assignment itself lives on the ADE token, which Graph serves only in beta. So the column is hidden for an Intune connection rather than filled with the wrong answer.

## Commands are queued, not confirmed

Every action answers `204 No Content`, which means Intune accepted it — not that the device has acted on it. Intune records the outcome separately as a device action result, and the console can take a while to show it; Checkpoint does not poll for it. A command that Checkpoint reports as sent and that never visibly happens is a matter for the device and the console, not for the request.

## Deleting versus retiring

These are two different things in Intune, and Checkpoint keeps them apart:

- **Delete Record** removes the Intune record and leaves the device alone. It stays enrolled and reappears at its next check-in.
- **Remove MDM Profile** sends Intune's *retire*, which removes company data and the management profile. The record goes too, once the device acknowledges.

On the Jamf products, removing the MDM profile leaves the record in place, which is why the confirmation spells out what happens instead of relying on the command's name.

## Device groups

The **Group…** button is hidden for an Intune connection. Intune's equivalent grouping is an Entra group, which is not a device group, and Checkpoint does not read them. Serial numbers can still be pasted or imported, and an Apple order can still be used.
