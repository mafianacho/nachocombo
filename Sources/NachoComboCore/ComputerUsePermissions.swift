import Foundation

/// What Computer Use can serve with the OS permissions that are granted right now.
///
/// A tool group whose permission is missing is switched off for this run only (the saved settings keep it on), so
/// the other groups still work: with Screen Recording allowed and Accessibility missing, the server opens with the
/// Screen group and lists no Input / Apps & Windows tools until Accessibility is allowed. The server stays closed
/// only when every switched-on group is blocked.
public struct ComputerUsePermissionPlan: Equatable {
    /// Permissions needed by switched-on groups that the system has not granted (sorted).
    public let missing: [OSPermission]
    /// Switched-on groups that are off for now because one of their permissions is missing.
    public let blockedGroups: [ToolGroup]
    /// The settings the server runs with: `blockedGroups` switched off, everything else unchanged.
    public let servable: ComputerUseSettings

    /// False only when groups are switched on and every one of them is blocked. With no group on, the server opens
    /// (it lists no tools), as before.
    public var canOpen: Bool {
        blockedGroups.isEmpty || !servable.enabledToolGroups.isEmpty
    }
}

extension ComputerUseSettings {
    /// Splits the switched-on groups into the ones that can run now and the ones that wait for a permission.
    /// `granted` is asked once per permission.
    public func permissionPlan(granted: (OSPermission) -> Bool) -> ComputerUsePermissionPlan {
        var answers: [OSPermission: Bool] = [:]
        for permission in requiredPermissions { answers[permission] = granted(permission) }
        let missing = requiredPermissions.filter { answers[$0] == false }
        var servable = self
        var blocked: [ToolGroup] = []
        for group in enabledToolGroups where group.requiredPermissions.contains(where: { answers[$0] == false }) {
            blocked.append(group)
            servable.setEnabled(group, false)
        }
        return ComputerUsePermissionPlan(missing: missing, blockedGroups: blocked, servable: servable)
    }
}

/// Where the running copy of the app lives, and what that means for macOS privacy permissions.
public struct AppLocationDiagnosis: Equatable {
    public enum Warning: Equatable {
        /// Gatekeeper's App Translocation runs a quarantined app from a random read-only folder: a permission given
        /// to the copy in Downloads may not apply to the copy that runs, and in-place updates are impossible.
        case translocated
        /// Running straight from the mounted disk image.
        case diskImage
        /// Not inside an Applications folder (works, but the copy is easy to duplicate or replace by mistake).
        case outsideApplications
    }

    public let path: String
    public let warnings: [Warning]

    public var isTranslocated: Bool { warnings.contains(.translocated) }

    /// `bundlePath` is the running bundle's path, `home` the user's home folder (for ~/Applications).
    public static func diagnose(bundlePath: String, home: String) -> AppLocationDiagnosis {
        if bundlePath.contains("/AppTranslocation/") {
            return AppLocationDiagnosis(path: bundlePath, warnings: [.translocated])
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return AppLocationDiagnosis(path: bundlePath, warnings: [.diskImage])
        }
        let homeApps = (home.hasSuffix("/") ? home : home + "/") + "Applications/"
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(homeApps) {
            return AppLocationDiagnosis(path: bundlePath, warnings: [])
        }
        return AppLocationDiagnosis(path: bundlePath, warnings: [.outsideApplications])
    }

    public static func message(for warning: Warning) -> String {
        switch warning {
        case .translocated:
            return "macOS is running this copy from a temporary, read-only folder (App Translocation), so a permission "
                + "you allow may belong to another copy. Quit Nacho Combo, move it to the Applications folder in Finder "
                + "and open it from there, then allow the permission again."
        case .diskImage:
            return "This copy runs from the disk image. Quit it, drag Nacho Combo to the Applications folder and open "
                + "it from there, then allow the permission again."
        case .outsideApplications:
            return "This copy is not in the Applications folder. If several copies exist, macOS may have the "
                + "permission on another one: keep a single copy in Applications."
        }
    }
}

/// The `tccutil` call that clears one privacy permission of this app, so macOS asks again from scratch.
public enum PermissionReset {
    /// tccutil service names of the permissions the app can reset.
    public static func service(for permission: OSPermission) -> String? {
        switch permission {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "ScreenCapture"
        case .automation: return nil
        }
    }

    /// Arguments for /usr/bin/tccutil, or nil when the bundle id is not a plain reverse-DNS name (never reset
    /// "all apps" by passing an empty or odd id).
    public static func arguments(for permission: OSPermission, bundleID: String?) -> [String]? {
        guard let service = service(for: permission), let id = bundleID, isPlainBundleID(id) else { return nil }
        return ["reset", service, id]
    }

    public static func isPlainBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, id.count <= 155, id.first?.isLetter == true, id.first?.isASCII == true else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { allowed.contains($0) } }
    }
}
