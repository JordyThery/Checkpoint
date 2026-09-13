# Features

What Checkpoint does beyond reporting, and how each part behaves. For what to grant each service, see [Permissions](permissions.md).

> This page describes the release it ships with. Opening it from a tag shows that version.

## Actions

Every action works on a single device or in bulk across a multi-selection, and always asks for confirmation first.

| Service | Actions |
| --- | --- |
| Apple Business, Apple School Manager | Assign or unassign the MDM server. Schedule a migration to another MDM server with a deadline, then update or cancel it. Release a device from the organization — Apple Business only, as Apple School Manager defines no release activity |
| Jamf Pro | Change PreStage scope, for computers and mobile devices. Change the site. Delete the device record |
| Jamf School | Change the location. Move the record to the trash, from where Jamf School can restore it |

Multiple organizations, of either Apple service, and multiple Jamf servers, of either product, can be configured together and switched from the toolbar. Everything Checkpoint sends is recorded in the [activity log](#activity-log).

## MDM commands

**Jamf Pro** — computers: Lock, Renew MDM Profile, Redeploy Jamf Framework, Wipe, Send Blank Push, Remove MDM Profile. Mobile devices: Update Inventory, Lock, Clear Passcode, Restart, Shut Down, Wipe, Remove MDM Profile, Send Blank Push, Renew MDM Profile.

**Jamf School** — Update Inventory, Restart, Wipe, Remove MDM Profile. Jamf School draws no distinction between computers and mobile devices, so all four reach Macs as well as iPads. Its API defines no lock, shut down or lost mode, and serves clearing a passcode only through a teacher session rather than an administrative one.

## Looking up a group or an order

**Group…** lists every computer and mobile device group on the selected Jamf Pro server, smart and static alike, and loads the members of the one you pick. Jamf School keeps one list rather than splitting by device kind, so it lists every device group with its size.

**Order…** lists the Apple order numbers in your organization with the number of devices on each. Apple cannot search devices by order number, so Checkpoint reads the device list once and reuses it; the first use takes about a minute and later ones are immediate.

Both fill the serial field, and both confirm before starting when the list is large or when the Apple organization has to be read first — neither a group name nor an order number reveals that it covers several hundred devices, or that it will take a minute.

![The order picker listing Apple School Manager order numbers with the number of devices on each](screenshot-order.png)

## Reading in bulk

Above 15 devices the Apple organization is read in bulk instead of one device at a time. Apple allows an organization only about twenty requests a minute and offers no way to filter the device list, so asking per device does not scale: a few hundred devices would otherwise take the best part of an hour. Reading the whole organization costs one request per thousand devices plus one per MDM server — about twenty for a typical organization — and a 389-device group completes in a little over a minute.

**AppleCare coverage** is the one thing not available in bulk, because Apple serves it only per device. In a bulk lookup that column reads "Select to load" and fills in when you select the device. **Passcode state on Jamf School** works the same way, for the same reason: it appears only in that product's per-device record, not in its device list.

Jamf School has no request quota and no pagination, and serves the whole instance in one request, so a lookup of any size costs one request there whatever its size.

## Filtering the results

**Filter** narrows the list to devices matching every chosen criterion: Apple organization status, MDM server, PreStage or ADE profile, site or location, and conditions worth singling out — an expired MDM profile, a migration in progress, FileVault off, no passcode, or a device present in one system and not the other. Combined with Select All, this is how a bulk action is aimed: filter to the devices with an expired profile, select them, renew.

The menu offers only what the devices in front of you actually use, with a count beside each: a list of Macs shows the four PreStages they are in rather than every PreStage on the server, and criteria that cannot apply to the list are left out.

Filtering only reads what the lookup already fetched, so it costs nothing. Warranty coverage and software update state are deliberately not filterable, and passcode state is not filterable on Jamf School: none is present for every row, so filtering on them would quietly exclude devices whose value had simply not been fetched.

Hiding a device also deselects it, so an action can never reach a device you can no longer see.

## MDM server migration

Assigning a device to a different MDM server normally takes effect on the next wipe or enrollment. Apple can instead schedule a *migration*: the device keeps running under its current service until it moves, nothing is erased, and Apple prompts the user and enforces the deadline on-device. Checkpoint shows the migration status and deadline for each device, and can schedule, reschedule or cancel one, individually or in bulk.

Deadlines cannot be more than 90 days out, and shortening a deadline, or setting one in the past, applies immediately without giving the user a chance to delay. Devices Apple reports as not migration-capable are skipped, and the option only appears when a device is eligible.

## Software updates and declarations

Jamf Pro only. Software update state comes from the device's own declarative status report rather than from Jamf Pro's deprecated update plans, and `install-state` is what says whether anything is pending. The version, deadline and failure beside it are kept by the report long after they stop being true, so they are shown only while an update is outstanding.

Alongside it, Checkpoint shows what the device made of the declarations sent to it. This is the device's verdict rather than the server's intent, and they can disagree entirely: Jamf Pro reports a blueprint as deployed once it has handed the declaration over, while the device decides whether it can be applied. A rejected software update declaration means nothing is enforcing updates, however healthy the blueprint looks — and the device's reason is shown as written, because it names the version at fault.

The enforced target and its install-by date are read back from the declaration, since the status report names a device's declarations without saying what they contain. On a Platform API connection the blueprint is named and linked; a direct connection shows its identifier, blueprints having no endpoint on a Jamf Pro instance.

## Recovery secrets

Jamf Pro only. For Macs, Checkpoint can show the **FileVault personal recovery key**, the **Recovery Lock password**, the **device lock PIN**, and the password for each **managed local administrator account**. Unlike the actions above these are single-device only, are not part of a lookup, and are fetched only when you ask for one. The value appears in a sheet for as long as it is open and is never written to the table, kept on the device record, or included in an export.

Managed local administrator accounts are listed as Jamf Pro lists them, one row per account with its source, so a Mac carrying both a PreStage account and one created by the Jamf binary shows both under their own usernames. Viewing a password causes Jamf Pro to rotate it after the instance's rotation time, so Checkpoint asks for confirmation first and records the view as a change.

## Activity log

Window → Activity Log (⌥⌘L) shows what Checkpoint asked each service to do and how it answered, in two tiers: the action you requested, and each HTTP request made to carry it out. It is searchable by serial number, so you can follow one device through a bulk operation, and it records reads of recovery secrets as well as changes.

The log is held in memory only and is discarded when Checkpoint quits. Nothing is written to disk, and no secret reaches it: request headers are never recorded, sign-ins are logged without either body, and the endpoints carrying a recovery key, password, PIN or unlock token withhold their bodies entirely. Jamf School attaches an owner to every device record, so the owner and any notes are withheld too — in a school those are pupils.

![The activity log listing requests to Apple School Manager and Jamf School, with the response body of the selected request below](screenshot-activity-log.png)

Copy and export each come in a masked form, replacing serial numbers, UDIDs and hardware addresses with `<device 1>`, `<device 2>` and so on — consistently, so a device stays recognisable without being named. Use it when attaching a log to a bug report.
