# Checkpoint: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Activation Lock clearing (Apple):** clearing will only ever go through Apple’s API, when Apple offers it. When the Apple Business or Apple School Manager API gains it, propose a clear action.
- **Graph beta-only features (Microsoft):** Checkpoint ships only what is in Graph v1.0. Recheck when a beta-only feature Checkpoint could use reaches v1.0.
- **Platform API for Jamf School (Jamf):** not worth it until an inventory permission or more actions appear. Recheck when Jamf adds them.
- **Renew MDM Profile over the Platform API gateway (Jamf):** returns 200 but lists every device under `udidsNotProcessed`, so it is dimmed there. Recheck after Jamf Pro updates; if fixed, undim it.
- **Jamf Pro `serverUuid` (Jamf):** findings depend on it; if Jamf drops it, classification degrades silently. Recheck after Jamf Pro updates.
