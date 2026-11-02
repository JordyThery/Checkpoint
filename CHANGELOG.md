# Changelog

## 2.10.0 — 2026-11-02

### Lookups

- **Small lookups ask Apple for up to fifty devices at once,** using Apple’s
  new serial number filter. With several organizations in scope, a device
  costs nothing in an organization that doesn’t hold it, so these lookups
  finish sooner and use less of Apple’s per-minute limit.
- **Renaming an Apple organization keeps what was read from it.** The next
  large lookup no longer asks to read the organization again.
- **When a service asks Checkpoint to wait before trying again,** the wait
  shows in the window with a Stop button, which ends it at once.
- **Jamf School check-in times** are read exactly as Jamf School reports them,
  so a time near a daylight-saving change is no longer an hour off.
- **A Keychain that can’t be read is reported as such,** instead of as a
  missing secret.

### Window and menus

- **One main window.** Every window showed the same results, so File › New
  Window is gone; File › Import Serial Numbers… (⌘O) takes its place.
- **A Lookup menu:** Look Up (⌘↩), Look Up Group…, Look Up Order… (⇧⌘O),
  Stop Waiting (⌘.) and Clear List (⌘K).
- **A status bar** at the bottom of the window shows a lookup’s progress,
  waits, the device count and the outcome of the last command. It replaces
  the “Command Sent” message, which had to be dismissed.
- **Demo Mode is marked in the window,** with a button to turn it off.
- **Statuses read in words and badges,** not by color alone: Assigned,
  Unassigned, Released, Not in organization, expired coverage, an expired
  MDM profile, an overdue report. A dimmed action says why below it.
- **Bulk actions show their device count the same way,** e.g. “Apply Site
  (4)”. The single-device buttons read “Apply Site”, “Apply Location” and
  “Apply PreStage”.
- The Group and Order lists have a visible search field, and a double-click
  picks a group or an order.
- The link column is named “Link”; the right-click menu names the product
  the records are in.
- The Settings button left the toolbar: Settings is in the Checkpoint menu
  (⌘,).
- Import offers text and CSV files only.
- The Appearance setting is gone: Checkpoint follows the Mac’s appearance.

### Settings and the activity log

- **An Apple private key can be pasted,** or imported from any text file
  that holds it (`.pem`, `.p8`, `.txt`).
- **Copy Log and Copy Log, Devices Masked** are back in the activity log.
- Changing a connection’s service now says plainly that the stored secret is
  removed on Save.

## 2.9.1 — 2026-11-01

- **A Jamf Pro or Jamf School server URL saved without `https://` works
  again,** as it did in 2.8.1. In 2.9.0 every lookup on such a connection
  failed and Settings wouldn’t save it. Settings now shows the address with
  `https://` and saves it so at the next edit; the stored secret is kept.
  An `http://` address is still refused: change it to `https://`.
- **The Activity Log shortcut is ⇧⌘L** since 2.9.0 (it was ⌥⌘L).
- **Command confirmations ask for the PIN twice, and for the device count
  when two or more devices are selected,** since 2.9.0.

## 2.9.0 — 2026-10-31

### Findings

- **A record is called stale only on evidence:** its device is no longer
  managed there, or it was last heard from before the working record.
  Enrollment type alone no longer decides. When Apple’s assignment couldn’t
  be read, the finding is unverified rather than “Unassigned”.
- **Remove Stale Records removes exactly the records the finding names.**
- **Jamf Pro reports whether a device is managed and supervised** (columns,
  filters and inspector), as Jamf School and Intune do.
- **All Connections reads two Platform API connections to different
  environments separately.** They could collapse into one when neither had a
  Jamf Pro web address.

### Actions

- **An action on an “Also on…” record goes to that record’s own
  connection.** If that connection was removed in Settings after the lookup,
  the action is refused with “The connection this record came from is no
  longer configured. Look the device up again.” It no longer falls back to
  the toolbar’s connection, which could hold a different record under the
  same ID.
- **Records with the same ID on two connections are told apart.** Two Jamf
  Pro servers that both have record 7 no longer share one “Also on…” section
  or one removal button.
- **Every record removal is refused without its confirmation:** Delete
  Record, Move to Trash and Remove Stale Records, for Jamf Pro and Jamf
  School as for Intune.
- **The refresh after an action reads the connections and organizations the
  lookup read,** even when the toolbar has changed since.
- **A partly failed Apple write, PreStage change or location move refreshes
  the rows and says what was done,** for example how many devices moved, or
  that devices were removed from their PreStage but couldn’t be added to the
  new one.
- **The bulk Site, Location and PreStage buttons and their confirmations
  count only the devices that would change,** and are unavailable when none
  would.
- **A command that reached some devices says how many,** beside the
  failures.
- **A refused command confirmation shows why.**
- **Schedule Migration skips released devices,** as Assign and Unassign do.
- **Irreversible commands and Lock Computer are sent only with the answer to
  their confirmation.** The confirmations themselves are unchanged.

### Lookups and the inspector

- **Choosing Order… asks before reading an organization in full.**
- **The confirmation for a large group or order always appears after picking
  it.**
- **The inspector never shows another device’s history or read errors** after
  the selection changes, and the Blueprint link opens the record’s own Jamf
  Pro.
- **A revealed secret can’t be selected and copied.** Copy, which clears the
  clipboard after 60 seconds, is the only way to take it.
- **Blueprint names that couldn’t be read are tried again.**
- **The Keychain is read less often while browsing.** The main window no
  longer reads it on every redraw.

### Other

- **Upgrading from 1.x:** if the Keychain refuses to copy the Apple key, the
  move is retried at the next launch instead of leaving the organization
  without its key.
- **Under tests (the release check), record changes are refused too:**
  delete, Move to Trash, site, PreStage, location and asset tag.
- **`-JTKitSandbox NO` is an ordinary launch.** The argument is read as
  JTKit’s demo mode reads it (YES, true or 1).
- **JTKit 1.0.0.** Command and error texts follow JTKit’s wording (“can’t be
  undone”), and the activity log names Apple’s service “Apple Business”,
  also in Checkpoint’s own Action entries.
