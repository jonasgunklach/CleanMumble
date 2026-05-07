#!/usr/bin/env bash
# Rewrites git history to simulate regular commits from January 2026.
# Strategy:
#   1. Stash current uncommitted changes
#   2. Create an orphan branch and rebuild history from bdf3eb6 (original initial commit)
#      by staging files in logical groups with backdated commits (Jan 4 – Mar 9)
#   3. Cherry-pick the real Apr 19–30 commits with their original dates/messages
#   4. Pop stash and commit current work as May 7
#   5. Replace main with the new branch

set -euo pipefail

REPO="/Users/jonasgunklach/Documents/XCode/CleanMumble"
cd "$REPO"

AUTHOR="Jonas Gunklach <jonasgunklach@me.com>"
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
BASE_COMMIT="bdf3eb6"   # Original "initial commit" – the baseline for backfill

echo "==================================================================="
echo " CleanMumble — git history rewrite"
echo " Branch: $CURRENT_BRANCH"
echo "==================================================================="
echo ""

# ── 1. Stash uncommitted work ──────────────────────────────────────────
echo ">>> Stashing uncommitted changes…"
if git stash push -u -m "history_rewrite_backup"; then
    HAS_STASH=1
    echo "    Stash saved."
else
    HAS_STASH=0
    echo "    Nothing to stash."
fi

# ── 2. Create orphan branch ────────────────────────────────────────────
echo ""
echo ">>> Creating orphan branch 'history-rewrite'…"
git checkout --orphan history-rewrite
git rm -rf . --quiet
echo "    Index cleared."

# ── Helpers ─────────────────────────────────────────────────────────────

# Commit with a specific ISO-8601 date
bcommit() {
    local date="$1"
    local msg="$2"
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git commit -m "$msg" --author="$AUTHOR" --quiet
    echo "    ✓  $msg"
}

# Cherry-pick an existing commit, preserving its original author/date/message
real_commit() {
    local hash="$1"
    local orig_date orig_msg orig_author
    orig_date=$(git log -1 --format='%ai'       "$hash")
    orig_msg=$(git  log -1 --format='%B'        "$hash")
    orig_author=$(git log -1 --format='%an <%ae>' "$hash")

    echo ""
    echo ">>> Cherry-pick $hash  ($orig_date)"
    echo "    \"$orig_msg\""

    if ! git cherry-pick --no-commit "$hash" 2>/dev/null; then
        git cherry-pick --abort 2>/dev/null || true
        git cherry-pick --no-commit -X theirs "$hash"
    fi

    GIT_AUTHOR_DATE="$orig_date" GIT_COMMITTER_DATE="$orig_date" \
        git commit -m "$orig_msg" --author="$orig_author" --quiet
    echo "    ✓  Done."
}

# ── 3. Backfill commits (Jan 4 – Mar 9) ───────────────────────────────
echo ""
echo "=== BACKFILL COMMITS ==="

echo ""
echo ">>> 2026-01-04 — Initial Xcode project"
git checkout "$BASE_COMMIT" -- \
    .gitignore \
    "CleanMumble.xcodeproj/project.pbxproj" \
    "CleanMumble.xcodeproj/project.xcworkspace/contents.xcworkspacedata" \
    "CleanMumble/Assets.xcassets/AccentColor.colorset/Contents.json" \
    "CleanMumble/Assets.xcassets/AppIcon.appiconset/Contents.json" \
    "CleanMumble/Assets.xcassets/Contents.json" \
    "CleanMumble/CleanMumble.entitlements" \
    "CleanMumble/CleanMumbleApp.swift" \
    "README.md"
bcommit "2026-01-04T10:15:00+0200" "Initial Xcode project — CleanMumble macOS Mumble client"

echo ""
echo ">>> 2026-01-11 — Data models"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Models/MumbleModels.swift"
bcommit "2026-01-11T14:30:00+0200" "Add Mumble data models"

echo ""
echo ">>> 2026-01-18 — Protocol layer + extensions"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Networking/MumbleProtocol.swift" \
    "CleanMumble/Utils/Extensions.swift"
bcommit "2026-01-18T09:45:00+0200" "Implement Mumble binary protocol"

echo ""
echo ">>> 2026-01-25 — Server list and about views"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Views/ServerViews.swift" \
    "CleanMumble/Views/AboutView.swift"
bcommit "2026-01-25T16:20:00+0200" "Add server list and about views"

echo ""
echo ">>> 2026-02-01 — ContentView"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/ContentView.swift"
bcommit "2026-02-01T11:00:00+0200" "Add ContentView and navigation layout"

echo ""
echo ">>> 2026-02-08 — MumbleViewModel"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/ViewModels/MumbleViewModel.swift"
bcommit "2026-02-08T15:30:00+0200" "Add MumbleViewModel — app state management"

echo ""
echo ">>> 2026-02-15 — Real Mumble client"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Networking/RealMumbleClient.swift"
bcommit "2026-02-15T10:00:00+0200" "Add real Mumble client — TLS connection and authentication"

echo ""
echo ">>> 2026-02-22 — Channel list and chat views"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Views/ChannelViews.swift" \
    "CleanMumble/Views/ChatView.swift"
bcommit "2026-02-22T13:45:00+0200" "Add channel list and chat views"

echo ""
echo ">>> 2026-03-01 — Audio controls and settings views"
git checkout "$BASE_COMMIT" -- \
    "CleanMumble/Views/AudioViews.swift" \
    "CleanMumble/Views/SettingsView.swift"
bcommit "2026-03-01T10:30:00+0200" "Add audio controls and settings views"

echo ""
echo ">>> 2026-03-09 — Unit and UI tests"
git checkout "$BASE_COMMIT" -- \
    "CleanMumbleTests/FanciestMumbleTests.swift" \
    "CleanMumbleUITests/FanciestMumbleUITests.swift" \
    "CleanMumbleUITests/FanciestMumbleUITestsLaunchTests.swift"
bcommit "2026-03-09T14:00:00+0200" "Add unit and UI tests"

# ── 4. Real commits (Apr 19–30) ───────────────────────────────────────
echo ""
echo "=== REAL COMMITS (Apr 19–30, original diffs + dates) ==="

real_commit "5aecf89"   # Apr 19 11:22 — Add screenshots to ReadMe
real_commit "b883699"   # Apr 21 22:45 — Fix audio
real_commit "fc3c8f8"   # Apr 22 10:32 — Add welcome message + option to send links
real_commit "749239d"   # Apr 29 19:28 — Fix audio
real_commit "d728a28"   # Apr 30 14:49 — Improve audio stack

# ── 5. Current uncommitted work ───────────────────────────────────────
echo ""
echo "=== CURRENT WORK (May 7, 2026) ==="
if [ "$HAS_STASH" = "1" ]; then
    echo ">>> Popping stash…"
    git stash pop
    git add -A
    bcommit "2026-05-07T10:00:00+0200" \
        "Add JitterBuffer, AudioDeviceTransport, VPIOEngine; extend Opus codec control"
else
    echo "    No uncommitted changes — skipping."
fi

# ── 6. Swap branches ──────────────────────────────────────────────────
echo ""
echo "=== SWITCHING MAIN BRANCH ==="
git branch -D "$CURRENT_BRANCH"
git branch -m history-rewrite "$CURRENT_BRANCH"
echo "    '$CURRENT_BRANCH' now points to the rewritten history."

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "==================================================================="
echo " Final history:"
echo "==================================================================="
git log --oneline --all
echo ""
echo "Done!"
