# Checkpoint: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What it is

A macOS app for Mac admins and MSPs. Enter serial numbers (typed, pasted, from a file, a Jamf group or an Apple order) and see, per device, what Apple Business / Apple School Manager says next to what Jamf Pro, Jamf School or Intune says, then fix what doesn't match from the same window. It also finds stale or misplaced MDM records across several connections. It erases and unmanages devices, so correctness and clear wording come first.

## How to work on it

- App-only work: open `~/Developer/Checkpoint/Checkpoint.xcodeproj`. It builds against the published JTKit.
- Anything that changes JTKit: use `~/Developer/Apps.xcworkspace`, which builds every app against the local JTKit.
- Build releases from the app's own project only.
- Never have Checkpoint open in both at the same time.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- Jordy is not a programmer: explain changes in plain language, work in small steps, and wait for his go before starting a planned feature.

## Architecture

- `CheckpointApp.swift`: scenes. JTKit's `SettingsWindow` (General + Connections tabs), `AboutWindow`, `ActivityLogWindow`, `AppInfoCommands`, `ConnectionCommands`, `UpdateChecker`.
- `ContentView.swift`: the results table (column groups as `@TableColumnBuilder` properties), toolbar pickers, the bulk-read consent text.
- `Model/LookupModel.swift`: the core. Lookups, per-connection targets and their prologue reads, session caches, findings (verdicts), actions, `refreshRows`. Also Checkpoint's `MDMCommand` extension: which commands each product offers and in which order.
- `Model/ManagedDevice.swift`: `ManagedDeviceInfo`, the product-neutral record every MDM maps into.
- `Model/DeviceFilters.swift`, `Model/Confirmations.swift`: filters; Apple write and typed confirmations.
- `API/JamfClient.swift`, `API/JamfSchoolClient.swift`, `API/ABMClient.swift`: thin layers over JTKit that keep the shapes the app reads. Intune has no app client: `LookupModel` uses JTKit's `Graph.Client` with `EntraTokenProvider`.
- `Support/AppSettings.swift`: `MDMProduct`, `MDMCapabilities`, `MDMAuthMethod`, `MDMConnection`, `ABMConfig`, `AppSettings`.
- `Support/CheckpointConnections.swift`: Checkpoint's adapter for JTKit's connection store (two lists shown as one), Keychain naming, the legacy Apple-key move.
- `Support/ActivityRecording.swift`: service names and Action entries for JTKit's activity log.
- `Views/`: inspector (`DeviceDetailView`), bulk actions, command confirmation sheet, group and order pickers, Settings sections.
- `docs/`: user reference (`features.md`, `permissions.md`, `platform-api.md`, `intune.md`). README keeps only the overview.

### What JTKit provides (don't duplicate it)

Connections list, editor, pickers and "All" (`ConnectionStore`, `ConnectionPicker`, `ConnectionCommands`, `AllConnectionsChoice`), `KeychainSecretStore`, sign-in and `HTTPClient` with retries, the activity log with masked export, `JamfPlatform.Client` (direct and gateway), `JamfPro` lookups/records/batches/secrets, `JamfClassic` groups, `JamfSchool.Client`, `MDMCommand` (titles, consequences, PIN and typed-confirmation rules, routing, privileges), `Graph`/`EntraTokenProvider`, `ABM` (client, token, snapshot, activities, audit events, `RetryRules.appleBusiness`), `SecretPasteboard`, `FormEncoding`. Tests use `JTKitTestSupport` (`MockServer`).

If a call, rule or text is missing, extend JTKit instead of adding another copy here. Checkpoint keeps: which commands each product offers, confirmation and reveal sheets, the one-connection-at-a-time rule, `ManagedDeviceInfo`, filters, findings, and its wording of records.

## Stored data: never rename

- Keychain service `DeviceStatus.secrets` (pre-rename name); accounts `abm.<UUID>` (Apple private key) and `jamf.<UUID>` (every MDM secret, Intune and Jamf School included).
- UserDefaults: `abmOrgs`, `jamfServers`, `appleConnectionChoice`, `mdmConnectionChoice`, `configurationHintDismissed`, `resultsTableColumns`.
- Table `customizationID`s are persisted: never change one.
- Keep these fallbacks: `MDMConnection` reads the pre-2.3 `flavor` key when `product` is missing; new stored fields use `decodeIfPresent`; `LegacyABMMigration` moves the 1.x `abmConfig` and its key (an Apple key can't be downloaded twice).
- When auditing persistence, diff against the synthesized keys of the commit before a rename, not against comments.

## Rules and decisions

- **Wording:** concise and professional everywhere: UI text, errors, comments, commits, release notes, docs. Say what happened and the one reason that matters. Errors: problem and remedy, no apology, no exclamation marks. Same condition, same sentence everywhere. Commits: subject plus at most a short paragraph.
- **Docs move with code, in the same commit.** Code sites that feed docs carry a comment naming them: `MDMCommand.commands(for:product:)` (privilege rows in `docs/permissions.md`), `unavailabilityReason(via:)` (the gateway list, repeated in `docs/platform-api.md` and the Settings warning), `JamfClient.gatewayPath(for:)`. Check both pages before any release that touched privileges, endpoints or gateway behaviour.
- **Capabilities:** `MDMCapabilities` is the inventory of what each product can show. A missing capability is a deliberate omission with a reason; columns and actions without a source are hidden, not shown empty.
- **Parity check:** whenever a vendor adds something, ask whether the other MDM connections have it and whether Checkpoint exposes it consistently.
- **Nothing written to disk:** the activity log is memory-only; Apple snapshots are cached per organization for the session only. No disk cache.
- **Scopes:** "All Organizations" and "All Connections" are opt-in per session, never the default, never saved.
- **Actions** act in one Apple organization and one MDM connection. A selection spanning several is blocked and names them (`appleActionOrg(for:)`, `mdmActionConnection(for:)`). Actions resolve their connection from the record, never silently from the toolbar choice.
- **Findings are automatic, no user setup.** Expected connection: Apple's assigned server ID matched to Jamf Pro's ADE token `serverUuid` first, ADE serial membership second. Liveness comes from activity and managed state, never from enrollment type alone. Two connections to the same instance are read once (`dedupedByInstance`). A device in no configured Apple organization is shown neutrally (filterable, no badge). Apple-managed records are never stale-cleanup candidates and can't be removed. Don't propose a "linked Apple services" setting.
- **Bulk Apple read:** at 15+ devices (`snapshotThreshold`) the organization is read whole after a consent dialog. Keep the dialog; no prefetch before consent.
- **Refresh after an action** re-reads device records and reuses the lookup's server lists; only PreStage scope is re-read after a PreStage change.
- **Secrets** (FileVault key, Recovery Lock, lock PIN, LAPS) are read one device at a time, shown in a sheet, never stored. Viewing a LAPS password asks first (it triggers rotation). Copying goes through `SecretPasteboard`. Clear Passcode reads the unlock token at send time; lookups never carry it.
- **Personal data:** Jamf School's device owner is not read at all. Jamf Pro user-and-location blocks and Apple audit actor/subject names are masked whole in the log.
- **Activation Lock:** read from Apple only (Jamf Pro's mobile flag is deliberately not shown). Clearing will only ever go through Apple's API when Apple offers it; don't add or suggest the Jamf School or Intune clear routes.
- **Current Jamf Pro only (cloud-first):** no API-version fallback chains. Keep the persistence fallbacks above.
- **Out of scope:** Blueprints/configurations/apps/packages, Apple users/groups/OUs, MDM server create/delete. Platform API for Jamf School is not worth it until an inventory permission or more actions appear. IMEI as a lookup key was cut for now.
- **Graph:** ship only what is in v1.0; beta-only features stay out.
- **Versioning:** new features bump the minor version; improvements and fixes bump the patch (Jordy decides when unclear).

## Verified API behaviour

### Apple Business / School Manager
- The token endpoint rate-limits hard. Reuse clients (cached per connection in `LookupModel`); during live probes don't mint a new client or `LookupModel` each time, and space probes out.
- About 18 requests per rolling minute per organization, every attempt and post-write check counted. Quota is per organization, so organizations can be read in parallel.
- Writes are asynchronous; JTKit watches the activity. A write is never repeated after a server error.
- Migration: scheduling assigns to the new server immediately and cancelling stops the move but doesn't undo the assignment (from notes, not verified in code); Apple reports a cancelled migration as `FAILED`, so Checkpoint shows both as "Not migrated" and hides a stale deadline.
- Activation Lock status fails with a server error for an internal-only lock state: show "Unknown", not "Disabled".
- Empty identifier arrays (IMEI, MEID, MACs) mean absent.
- Built-in device management (`APPLE_MDM`), Apple Business only: `mdmDevices` has no filters (read whole, match locally) and is read-only; detail is addressed by the list's resource ID, not the serial; FileVault and firewall read false on iPads, so those rows are Mac-only. The documented `deviceCount` field is rejected (from notes, not verified in code).
- Audit events: Apple Business only; start and end timestamps are required, ISO 8601 only. Histories can be short.

### Jamf Pro (direct and Platform API gateway)
- Username/password trap: sign-in can succeed with a token that reads nothing, so every lookup returns zero records. Suspect the auth method first when everything is "not found".
- Gateway paths: `/api/…` → `/pro/…`, `/JSSResource/…` → `/proclassic/…` (segment removed). Other platform APIs have their own prefix (`/devices`, `/device-actions`). An unknown prefix answers 404 "page not found"; an unknown route inside a valid prefix answers 403 BAD_PERMISSIONS, which does not mean a missing permission.
- Renew MDM Profile over the gateway returns 200 but lists every device under `udidsNotProcessed`, so it is dimmed there. Always read `udidsNotProcessed`, not the status. Blank push likewise reports failures in `errorUuids` inside a 2xx.
- Clear Passcode needs a non-empty unlock token, from the per-device mobile detail only (absent from the batched read).
- Batched lookups (50 serials): a refused filter is HTTP 400; that batch is retried one serial at a time. The HARDWARE section is required (the serial lives there); match serials case-insensitively.
- `serverUuid` on device-enrollment instances equals Apple's MDM server ID. Findings depend on it; if Jamf drops it, classification degrades silently.
- Enrollment method shapes: computers `enrolledViaAutomatedDeviceEnrollment` + `enrollmentMethod` object; mobile batched `enrollmentMethodPrestage` object (null when not ADE). `appleEnrollmentType` is unreliable; ignore it.
- Jamf reports "never" as the Unix epoch (seen on mobile last-contact dates): any date before 1971 means unknown, never inactive.
- A record's site is unrelated to its ADE token. Full-access site ("-1") is not in the sites list.
- Stale software-update enforcement declarations can report `valid=invalid` while Jamf's UI says "Deployed"; that is why the declaration row exists. Check semantics against Apple's device-management schemas.
- Jamf Pro privilege names come from JTKit's privilege table; check names there, not from memory.

### Jamf School
- Errors can arrive under HTTP 200: read `code`/`message` in the body. The whole fleet comes in one request.
- `GET /api/dep` needs `X-Server-Protocol-Version: 3`; skip `status: removed`. It can lag a reassignment.
- Its published field names and types are unreliable: verify against a live instance.

### Intune (Graph v1.0)
- `serialNumber` has no `$filter`: the tenant is read whole (1,000 per page) and matched locally.
- Every device action needs `DeviceManagementManagedDevices.PrivilegedOperations.All`; delete record needs `ReadWrite.All`.
- `enrollmentProfileName` is what a device enrolled with, not its assigned profile, so that column is hidden for Intune. `udid` is empty in list reads; actions use the managed device ID.
- Commands answer 204 meaning accepted, not done. Retire unmanages; Delete Record only removes the record.

### Looking up Jamf APIs
- Use Jamf's public MCP server at `https://developer.jamf.com/mcp` (via curl; it can't be registered in Xcode). Gateway specs are the `platform-api=` entries (the Jamf Pro one is now titled `platform-api=Jamf Pro`); `get-server-variables` gives each API's prefix. Never use `execute-request` against a live tenant without Jordy's permission.
- When a release note repeats a vendor limitation, retest it that day; never carry an old result forward.

## Testing

- Unit tests: `CheckpointTests` (Swift Testing), about 250 tests (connections, Apple, Jamf Pro reads, Jamf School, Intune, commands, networking, demo mode, under tests), plus the live checks, skipped on ⌘U. Run with ⌘U on the Checkpoint scheme. They use JTKit's `MockServer`, an in-memory Keychain, a virtual Apple clock and settings domains from `TestSettings`: a file path in the test process's own temporary folder, removed when it ends, never a file in Preferences (named `CheckpointTests.<UUID>` domains left one plist per test in the container's Preferences before, thousands in all). No real network, no waiting.
- As the unit-test host the app uses a throwaway settings domain and no Keychain (`UnderTest.unitTestHostSettings()`), and makes no update check.
- **Under tests nothing reaches a tenant it shouldn't** (decided by Jordy, JTKit ROADMAP step 11): `UnderTest` (the unit-test host and a sandbox launch) refuses, before anything is sent, every MDM command on every product (`sendCommand`, and again in `JamfClient`/`JamfSchoolClient.send`), every Apple write (`recordingActivity`, and again in `ABMClient.submitActivity`), the four device-secret reads, and every request of settings holding the saved connections (`SavedConnectionGuard`, also for Test Connection). Demo connections are exempt: they reach the in-app demo servers only. Each attempt goes to `tmp/Checkpoint-under-test/` in the container (`AttemptLog`); the release check fails on any. Unit tests on a mock server pass `underTest: .off`; `UnderTestTests` covers the guards.
- UI tests: `CheckpointUITests`, only `DemoSmokeUITests` (JTKit's `JTKitUITestSupport`, demo mode). The app's own scheme runs the unit tests only. There are no accessibility identifiers: the smoke tests find elements by label (in demo mode the menu reads "All Connections (Demo)").
- **Release check** (`Scripts/release-check.sh`, scheme "Checkpoint Release Check"; JTKit ROADMAP step 11), run unattended by Claude:
  - Live checks (`LiveCheckTests.swift`): apple-business and apple-school read only; up to 5 serials per organization from its own list (`ABM.Client.firstDevices`, one request), kept in memory, never in a report, looked up by the app's own `LookupModel` in Apple and every MDM tenant of the run (findings counted, nothing removed). JTKit paces Apple to 9 requests a minute and at most 40 a run per organization; a run takes about 21 each.
  - jamfpro-readonly, jamfschool-readonly, intune-test: read only (intune-test kept read only by `READ_ONLY_ROLES`); one serial from the tenant's own inventory, masked, found by the app's lookup; an empty inventory is "nothing to look up" with the counts. jamfpro-production the same, only with `--include-production`.
  - jamf-test-a (Platform API): the test code makes an unmanaged `JTKTEST CP … – Mac` computer and `… – iPad` mobile device record with made-up serials (`JTKTESTCM…`, `JTKTESTCP…`); the app's lookup finds both, alone and in the stale/misplaced view (All Connections: no finding, nothing offered for removal); the app's own Delete Record removes the iPad behind a fence (reads, sign-in and that one delete only); the test code removes the Mac; cleanup sweeps `JTKTEST` records.
  - Credentials: the Apple keys, jamfpro-readonly, jamfpro-production and intune-test from Checkpoint's own saved connections (matched by client ID, host or tenant ID, read only and copied into memory); jamfschool-readonly and jamf-test-a from the Keychain items the script reads.
  - App faults: `command-attempt` (an Erase of the test iPad through `sendCommand`) and `apple-write-attempt` (an Unassign of a made-up serial through `setMDMServer`); both are refused and fail the run.
  - Fingerprint (hashes only): `abmOrgs`, `jamfServers`, `appleConnectionChoice`, `mdmConnectionChoice`, `configurationHintDismissed`, `resultsTableColumns`, `demoMode` (the container's preferences file, by path) and the account names under `DeviceStatus.secrets`.
- Before moving or changing behaviour, write tests of today's behaviour first and run them against the old code.
- Global rule: never run the long UI suites of Jamf Deployer or AppSettings2Blueprint unless Jordy asks for a test by name.
- Release check and live sandbox checks: see JTKit ROADMAP step 11. Live checks run only against tenants on the local allow-list outside git. Never write tenant names, device serials or credentials into this repo.

## Releasing

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the project, commit and tag `vX.Y.Z` **before** archiving. The version is compiled into the app; verify it with `PlistBuddy -c "Print :CFBundleShortVersionString"` before zipping.
2. Archive, sign with Developer ID, notarize and staple (steps 2–3 are from notes, not checked against a script). To judge signing, use `codesign -dvvv` on the built app or Xcode's Signing pane, not `security find-identity`.
3. Verify: `codesign --verify --deep --strict`, `spctl -a -vvv -t install`, `xcrun stapler validate`. Zip with `ditto -c -k --keepParent` as `Checkpoint-X.Y.Z.zip`, unzip it elsewhere and run `spctl` again.
4. GitHub release with the zip and short release notes. The in-app updater reads `releases/latest`.
5. Update README and `docs/` if anything they say changed.
6. Website: the app's page is `jordythery.be/checkpoint.html` (source outside this repo). Only when the release changes the app enough to make that page untrue or incomplete (new column, filter, capability or requirement), remind Jordy to update it.
7. Then follow the release gate in JTKit/ROADMAP.md.
