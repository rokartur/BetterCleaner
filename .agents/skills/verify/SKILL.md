---
name: verify
description: Verify BetterCleaner in its real AppKit UI. Use when asked to run the app, confirm a change end to end, or capture UI evidence.
---

# Verify BetterCleaner

Verification is **evidence**: build the current source, drive the exact Debug process, and observe the requested state in its real AppKit UI. Use targeted tests for logic and UI evidence for user-visible behavior.

## Safety boundary

Restrict actions to transient UI navigation, scans, and read-only diagnostics. For controls that change files, Homebrew, services, preferences, permissions, or external systems, inspect their AX state or open their confirmation and choose **Cancel**. Treat an immediate mutation with no confirmation as inspect-only. Report **BLOCKED** when a check requires unapproved mutation or a new system permission.

## 1. Set the contract

Read the request, Git status, the working-tree/staged diff, and any committed branch diff from its merge-base; then trace callers of the changed behavior. Write a short checklist containing:

- every user-visible claim;
- one adjacent regression for each changed shared component;
- the exact observable pass state and safe starting state for each check.

Use only the matching regression probes below. A claim without a UI surface gets the narrowest automated check plus the nearest visible effect.

**Complete when:** every claim has a binary pass condition, and every mutating control is marked cancel-only or inspect-only.

## 2. Build and launch the exact artifact

Run the narrowest affected automated check first. A UI-only change with no relevant test goes directly to the build.

```bash
set -euo pipefail
project='BetterCleaner.xcodeproj'
scheme='BetterCleaner Debug'
destination='platform=macOS'

xcodebuild -project "$project" -scheme "$scheme" -destination "$destination" build
settings="$(xcodebuild -project "$project" -scheme "$scheme" -showBuildSettings 2>/dev/null)"
build_dir="$(awk -F' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' <<<"$settings")"
product="$(awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / { print $2; exit }' <<<"$settings")"
executable="$(awk -F' = ' '/^[[:space:]]*EXECUTABLE_NAME = / { print $2; exit }' <<<"$settings")"
app="$build_dir/$product"
test -d "$app"

old_pid="$(pgrep -nx "$executable" 2>/dev/null || true)"
open -na "$app"
app_pid=''
for _ in {1..50}; do
  candidate="$(pgrep -nx "$executable" 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != "$old_pid" ]]; then app_pid="$candidate"; break; fi
  sleep 0.2
done
test -n "$app_pid"
printf 'app=%s\npid=%s\n' "$app" "$app_pid"
```

Resolve the product from these build settings because repo-local `DerivedData` can be stale. Poll `System Events` for `window 1` owned by the printed PID for up to 10 seconds, then make that process frontmost.

**Complete when:** every selected automated check passes, `xcodebuild` exits 0, the resolved app exists, and that new PID owns a visible window. Classify Accessibility denial as **BLOCKED**.

## 3. Drive the user path

Reach each state through the visible controls a user would use.

1. Query the live AX tree for role, title/description, enabled state, value, position, and size before acting.
2. Select by semantics and use `AXPress`. For source-list rows that ignore AX press, compute the center from their current AX position and size and send one `CGEvent` click.
3. After a transition, discard old element references and query the new tree.
4. Poll a specific expected AX state with a bounded timeout; the resulting state is the evidence.

**Complete when:** every contract item and selected regression probe reaches its expected observable state, or has a recorded contradictory state (**FAIL**) or environmental blocker (**BLOCKED**).

## Regression probes

Run a probe only when its area is in the contract:

- **Window/navigation:** fresh launch shows **Applications** with Back and Forward disabled. Select **System Junk**; Back becomes enabled. Back restores **Applications** and enables Forward; Forward restores **System Junk**.
- **Homebrew routing/menu:** select **Homebrew**, press the button labelled `Homebrew actions: update, upgrade all, cleanup, and Brewfile`, then choose `Maintenance & Health…` by title. The window title becomes **Maintenance** and the page exposes Homebrew, Doctor, Cache, Analytics, and Statistics sections. Use AX inspection for mutation controls.
- **Destructive flow:** reach the confirmation sheet, verify its message and buttons, choose **Cancel**, and verify the sheet closes with the underlying state unchanged. For immediate mutations, verify only label, enabled state, and help text.

## 4. Capture and judge evidence

Capture only the layer-0 window owned by the verification PID:

```bash
: "${APP_PID:?Set APP_PID to the PID printed in step 2}"
app_pid="$APP_PID"
window_id="$(swift -e 'import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }), let number = window[kCGWindowNumber as String] as? Int { print(number) }
' "$app_pid")"
test -n "$window_id"
screencapture -x -l "$window_id" "/tmp/BetterCleaner-verify.png"
```

Read the screenshot and judge it against the contract; capture additional screenshots only for visually distinct required states. Quit only the process launched in step 2 and leave pre-existing instances running.

Report exactly:

```text
Result: PASS | FAIL | BLOCKED
Build: PASS | FAIL
Checks:
- PASS | FAIL | BLOCKED — claim — observed state
Evidence: AX observation and/or /tmp screenshot path
Skipped: unrelated probes, if any
```

**Complete when:** every contract item appears in the report. `PASS` requires a passing build and passing evidence for every item; unknown or unobserved items are **BLOCKED**.
