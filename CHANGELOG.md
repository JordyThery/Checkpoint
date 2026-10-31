# Changelog

## Unreleased

Fixes for what JTKit ROADMAP step 11 (the release check) found, 2026-10-30.

- **An action on an “Also on…” record goes to that record's own connection.**
  If its connection was deleted in Settings after the lookup, Remove, Delete
  Record, commands, asset tags, sites and the secret reads now refuse with
  “The connection this record came from is no longer configured. Look the
  device up again.” Before, they fell back to the connection chosen in the
  toolbar and could act on a different server's record with the same ID.
- **Records with the same ID on two connections are told apart.** The
  inspector's “Also on…” sections identify a record by its connection and its
  ID; two Jamf Pro servers that both have record 7 no longer share one section
  or one Remove button.
- **The main window no longer reads the Keychain on every redraw.** Whether
  an Apple organization has its private key is read once and again only after
  the organization or its key is saved or deleted.
- **`-JTKitSandbox NO` is an ordinary launch.** It used to give in-memory
  settings while still checking for updates; the argument is now read as
  JTKit's demo mode reads it (YES, true or 1).
- **Schedule Migration skips released devices,** as Assign and Unassign do.
- **JTKit 0.13.0.** Irreversible commands (Wipe, Remove MDM Profile, Retire,
  Intune's Delete Record) and Lock Computer are sent only with the answer to
  their confirmation; the confirmations themselves are unchanged. Command
  and error texts follow JTKit's wording (“can’t be undone”), and the
  activity log names Apple's service “Apple Business Manager”, also in
  Checkpoint's own Action entries.
