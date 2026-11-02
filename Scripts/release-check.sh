#!/bin/zsh
# Checkpoint’s release check. Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--include-production] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|command-attempt|apple-write-attempt
# Tenants are roles on the local allow-list (never named here):
# apple-business and apple-school (up to 5 devices each, read only; Apple
# writes are never sent), jamfpro-readonly, jamfschool-readonly and
# intune-test (read only; intune-test kept read only for Checkpoint),
# jamf-test-a over the Platform API (a JTKTEST computer and mobile device
# record, removed afterwards), and jamfpro-production, read only, only with
# --include-production (or the allow-list's productionReads). The live UI
# tests drive the real app (JTKit's live-check switch): lookups on the read
# roles, and Blank Push (Jamf Pro), Update Inventory (Jamf School) and Sync
# Device (Intune) to one listed test device each. No interruptive command,
# Apple write or device secret read is ever sent: the app refuses them all
# under tests, and any attempt fails the run.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Checkpoint"
APP_CODE="CP"
PROJECT="Checkpoint.xcodeproj"
SCHEME="Checkpoint Release Check"
UNIT_TESTS="CheckpointTests"
UI_TESTS="CheckpointUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/CheckpointUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="CheckpointTests/LiveSignInTests"
LIVE_TESTS=("CheckpointTests/LiveLookupTests/readOnlyLookups()"
            "CheckpointTests/LiveLookupTests/testRecords()"
            "CheckpointUITests/LiveUITests/testReadOnlyLookups"
            "CheckpointUITests/LiveUITests/testNonInterruptiveCommands")
CLEANUP_TEST="CheckpointTests/LiveCleanupTests"
ROLES=(apple-business apple-school jamfpro-readonly jamfschool-readonly intune-test jamf-test-a jamfpro-production)
# None. Roles that receive a device command in this app's run: those whose
# allow-list entries list test devices (today jamfpro-production, Blank Push;
# jamfschool-readonly, Update Inventory; intune-test, Sync Device), one listed
# test device each, non-interruptive only. Despite its name, jamfschool-readonly
# then gets that one command; every other request to it is a read. The app
# allows the two commands only through those roles' connections (JTKit's
# LiveLaunch.receivesCommands), and the gateway sends commands only to the
# listed devices. Nothing else is written beyond jamf-test-a's fenced delete.
READ_ONLY_ROLES=()
# role:service:item, read from the Keychain service the allow-list names:
# jamf-test-a only. The Apple keys, jamfpro-readonly, jamfpro-production,
# jamfschool-readonly and intune-test come from Checkpoint's own saved
# connections, read inside its test host: by the unit-test live checks
# themselves, and for the live UI tests by HOST_CREDENTIALS_TEST, which hands
# them to the gateway over its token (JTKit 1.3.1), never through a file.
CREDENTIALS=("jamf-test-a:jamfPlatform:client-id" "jamf-test-a:jamfPlatform:client-secret")
HOST_CREDENTIALS_TEST="CheckpointTests/LiveHostCredentialsTests"
LEGACY_PREFIXES=""
APP_FAULTS=(command-attempt apple-write-attempt)
DOMAIN="be.jordythery.checkpoint"
CONTAINER="$HOME/Library/Containers/$DOMAIN/Data"
# The app is sandboxed: its test host reaches only its own container.
TEST_HOST_CONTAINER="$DOMAIN"
# The saved organizations and connections, the ones in use, the hint, the
# table's columns and demo mode (hashes only), read from the container's
# preferences file by path.
FINGERPRINT_DEFAULTS=()
for key in abmOrgs jamfServers appleConnectionChoice mdmConnectionChoice configurationHintDismissed \
           resultsTableColumns demoMode; do
    FINGERPRINT_DEFAULTS+=("$CONTAINER/Library/Preferences/$DOMAIN $key")
done
# Nothing is written to disk (the activity log and Apple snapshots live in
# memory only): these must stay absent.
FINGERPRINT_PATHS=("$CONTAINER/Library/Application Support/Checkpoint"
                   "$CONTAINER/Library/Application Support/$DOMAIN"
                   "$CONTAINER/Library/Logs/Checkpoint")
KEYCHAIN_PREFIXES=("DeviceStatus.secrets")

# Each run starts with no recorded attempts (commands, Apple writes, secret
# reads, saved connections).
rm -rf "$CONTAINER/tmp/Checkpoint-under-test"

if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.4 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
