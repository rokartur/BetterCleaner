---
name: verify
description: Build and drive the BetterCleaner macOS app through its real AppKit UI.
---

# Verify BetterCleaner

1. Build the current Debug app, then resolve the real product directory (do not use repo-local `DerivedData`; it can be stale):

```bash
xcodebuild -project BetterCleaner.xcodeproj -scheme "BetterCleaner Debug" -destination 'platform=macOS' build
build_dir=$(xcodebuild -project BetterCleaner.xcodeproj -scheme "BetterCleaner Debug" -showBuildSettings 2>/dev/null | awk -F' = ' '/^[[:space:]]*TARGET_BUILD_DIR = /{print $2; exit}')
open -na "$build_dir/BetterCleaner Debug.app"
```

2. Drive the native UI with `System Events`; low-level `CGEvent` clicks are more reliable than Accessibility `click` for source-list rows. Query controls by accessibility role/description before acting.
3. Capture only the BetterCleaner window with `screencapture -l<CGWindowID>`; do not capture the full desktop.

## Core flows

- Navigation history: Back/Forward are both disabled on first launch; visiting another sidebar page enables Back; Back enables Forward; Forward restores the page.
- Homebrew Maintenance: open Homebrew's `…` menu and choose its last item (Up Arrow, Return). Confirm the Maintenance page renders and no removed/obsolete section remains.
- Destructive actions: open and cancel confirmation alerts only. Never confirm uninstall, zap, cleanup, or autoremove against the user's machine.
