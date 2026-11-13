import Foundation
import ServiceManagement

/// Prefer the modern login item API. If macOS refuses it for an ad-hoc signed
/// build, fall back to a user LaunchAgent so the toggle still works.
enum LoginItem {
    private static let label = "com.srihariphs.clipsync"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var launchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || launchAgentInstalled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval && !launchAgentInstalled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !isEnabled else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                try installLaunchAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgent()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func installLaunchAgent() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        let status = runLaunchctl(["bootstrap", domain, launchAgentURL.path])
        guard status == 0 else {
            try? fm.removeItem(at: launchAgentURL)
            throw NSError(
                domain: "ClipSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not add ClipSync to your login items."]
            )
        }
    }

    private static func removeLaunchAgent() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
