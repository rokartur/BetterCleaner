# BetterCleanerHelper — privileged SMAppService helper

A root LaunchDaemon that performs the privileged steps of a complete uninstall
(`launchctl bootout system/…`, moving system files to Trash, `pkgutil --forget`)
in **one** elevation, over a code-signature-verified XPC connection — so the user
isn't re-prompted for a password on every system-owned file.

## How it fits together

- **App side (already in the project, compiles today):**
  - `BetterCleaner/Logic/PrivilegedHelperProtocol.swift` — shared XPC contract.
  - `BetterCleaner/Logic/PrivilegedHelperClient.swift` — registers/connects to the
    daemon via `SMAppService.daemon(plistName:)` + `NSXPCConnection`.
  - `BetterCleaner/Logic/PrivilegedExecutor.swift` — prefers the helper; **falls
    back to `osascript`** when the helper isn't registered/approved.
- **Helper side (this folder, NOT yet an Xcode target):**
  - `main.swift` — the daemon: `NSXPCListener`, client code-signature check, runs
    the shell batch as root.
  - `com.rokartur.BetterCleaner.Helper.plist` — the launchd plist.

Until the helper target below is created, `PrivilegedHelperClient.shared` is `nil`
and **everything still works via the osascript fallback** (one admin prompt per
uninstall). Wiring the helper upgrades that to zero prompts after a one-time
approval — it does not add new functionality.

## One-time wiring (requires your signing identity)

Team `N529W98U62`, app id `com.rokartur.BetterCleaner` are already baked into
`main.swift`'s `clientRequirement` and the plist. If you change either, update
both.

1. **Add a target**: File → New → Target → **Command Line Tool** (macOS), product
   name `BetterCleanerHelper`, language Swift.
2. **Source membership**: add to the new target
   - `BetterCleanerHelper/main.swift`
   - `BetterCleaner/Logic/PrivilegedHelperProtocol.swift` (shared — tick the
     helper target in the File Inspector; leave the app target ticked too).
3. **Embed the launchd plist** into the *app*: add
   `com.rokartur.BetterCleaner.Helper.plist` and, in the app target's Build
   Phases, a **Copy Files** phase → Destination *Wrapper*, Subpath
   `Contents/Library/LaunchDaemons`, add the plist there. The helper executable is
   embedded automatically when you add a **Copy Files** phase → Destination
   *Executables* (or *Wrapper* subpath `Contents/MacOS`) copying the
   `BetterCleanerHelper` product. Mark the app target as **depending on** the
   helper target.
4. **Signing**: sign both with the same Team (`N529W98U62`). For local testing an
   *Apple Development* identity is fine; for distribution use *Developer ID*.
5. **Register at runtime**: call `try PrivilegedHelperClient.register()` once
   (e.g. from a Settings "Install privileged helper" button). macOS then shows the
   approval in **System Settings → General → Login Items → Allow in the
   Background**. Once approved, `SMAppService.daemon(...).status == .enabled` and
   `PrivilegedExecutor` routes through the helper automatically.

## Security notes

- The daemon accepts a connection only if the caller satisfies `clientRequirement`
  (anchored to Apple, the app's bundle ids, and the Team OU), checked via the
  connection's **audit token** (not a racy PID).
- The app composes every command from shell-quoted, trusted input
  (`PrivilegedRunner.quote`); the helper runs that batch via `/bin/sh -c` as root.
- Removals still go to the user's Trash (recoverable); the helper performs no
  destructive `rm`.

## Verify

- Signed build: trigger a system-file uninstall → exactly one approval the first
  time, **zero** password prompts thereafter.
- Unsigned/dev build (no helper): same uninstall completes via the osascript
  fallback with a single admin prompt.
