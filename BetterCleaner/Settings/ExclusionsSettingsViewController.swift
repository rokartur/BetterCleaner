import AppKit
import BetterSettings

/// Settings pane for the two scan-path lists: extra app-search roots and paths to
/// skip during scanning. Edits write straight back to `Preferences`; scans pick up
/// changes on their next run.
final class ExclusionsSettingsViewController: SettingsTabViewController {
    override func setupContent() {
        let roots = addSection(title: "Extra Scan Locations", anchor: "extra-roots")
        addRow(to: roots, title: "Search for apps in these folders",
               subtitle: "Added alongside /Applications and ~/Applications when listing installed apps.")
        let rootsList = PathListView(paths: Preferences.shared.extraScanPaths, addTitle: "Add Folder…")
        rootsList.onChange = { Preferences.shared.extraScanPaths = $0 }
        roots.addContent(rootsList)

        let exclusions = addSection(title: "Scan Exclusions", anchor: "exclusions")
        addRow(to: exclusions, title: "Never scan these folders",
               subtitle: "Skipped (with everything inside them) by the app, orphaned-files, and system-junk scans.")
        let exclusionsList = PathListView(paths: Preferences.shared.orphanExclusions, addTitle: "Add Folder…")
        exclusionsList.onChange = { Preferences.shared.orphanExclusions = $0 }
        exclusions.addContent(exclusionsList)
    }
}
