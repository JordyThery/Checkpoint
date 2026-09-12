# Platform API

Checkpoint can talk to Jamf Pro through Jamf's [Platform API gateway](https://developer.jamf.com/platform-api/reference/getting-started-with-platform-api) instead of connecting to the server directly. This is optional: an API client connection is simpler and carries every command.

> This page describes the release it ships with. What the gateway can and cannot carry changes as Jamf extends it, so opening this page from a tag shows what was true for that version.

## Setting one up

Create an **environment-scoped** integration in **Jamf Account**. Then in Checkpoint choose the **Platform API** method and supply:

- the client ID and client secret
- the gateway region
- the environment ID, found on the environment pill in the integration's **Integration details** panel
- the Jamf Pro URL, as for any other connection

A Jamf Pro API client will not work here — it has to be a Jamf Account integration. The region must match your environment, because gateway tokens are region-locked.

The Jamf Pro URL is still required even though requests go to the gateway: device rows link to their records in the Jamf Pro web interface, and the gateway host cannot serve those.

### Why environment scope

Environment scope is required rather than tenant scope. The Jamf Pro passthrough accepts either, but Restart and Shut Down run on Jamf's platform device actions, which accept only an environment ID. Environment scope is therefore a superset, and is what makes those two commands reachable.

Most Jamf Account instances already have an environment grouping their tenants, and you can create one if not.

## Scopes

Permissions are granted per capability on the integration, rather than per privilege as on a [Jamf Pro API role](permissions.md). The scope names below are the ones the API declares; the Jamf Account interface groups them under capability toggles, so a label there may read a little differently.

| Feature | Scope |
| --- | --- |
| Device lookup, including FileVault state and passcode state | `devices:read` |
| Software update state | `devices:read` |
| Looking up a group | `device-groups:read` |
| Sites | `sites:read` |
| PreStage display and changes | `prestage-enrollments:read`, `prestage-enrollments:update` |
| PreStage filtering per ADE token | `device-enrollment-program-instances:read` |
| MDM commands, except the two rows below | `device-actions:execute` |
| Wipe and Remove MDM Profile | `destructive-device-actions:execute` |
| Redeploy Jamf Framework | `device-actions:execute`, `computer-check-in:read` |
| Restart and Shut Down | `devices:read` to resolve the device, plus the device actions above |
| FileVault recovery key | `disk-encryption-recovery-key:read` |
| Recovery Lock password | `recovery-lock:read` |
| Device lock PIN | `computer-device-lock-pin:read` |
| Managed local administrator accounts and passwords | `local-admin-passwords:read` |

The four secrets take four separate scopes, so granting one does not grant the others. Deleting a device record and changing a site declare no scope in the specification; the corresponding [Jamf Pro privileges](permissions.md) are the guide there.

## What the gateway cannot carry

**Three commands are unavailable over the Platform API.** Checkpoint dims all three and explains why, so nothing fails halfway.

| Command | Why |
| --- | --- |
| Lock | Exists only as a command type on Jamf Pro's batched MDM command endpoint, which the gateway publishes as GET only |
| Clear Passcode | The same endpoint, for the same reason |
| Renew MDM Profile | Accepted by the gateway, but renews nothing: every device comes back under `udidsNotProcessed`, for computers and mobile devices alike, on an instance that renews them fine over a direct connection |

Everything else works, including lookups, PreStages, sites, Wipe, Remove MDM Profile, Restart and Shut Down. Use an API client connection when you need one of the three above.

FileVault state, mobile passcode state, software update state, managed local administrator accounts and the group lookup were each checked over both connections and returned identical results, so there is no difference in what Checkpoint can show.

Group membership comes from the Classic endpoints, which the gateway serves under `/proclassic`. The modern computer equivalent returns bare record IDs rather than serial numbers, which would cost a request per device to resolve.

## Notes on gateway behaviour

Two things worth knowing if you are debugging a connection with the [activity log](../README.md#activity-log) open:

- The gateway fronts the Jamf Pro API under `/pro` and the Classic API under `/proclassic`, replacing the product segment rather than prefixing it. Each platform API has its own prefix too: device inventory under `/devices`, device actions under `/device-actions`.
- An unknown product prefix answers `404 page not found`, while an unknown route within a valid prefix answers `403 BAD_PERMISSIONS`. A 403 therefore does not necessarily mean your capabilities are wrong.
