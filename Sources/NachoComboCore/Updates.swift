import Foundation

/// MAJOR.MINOR.PATCH with an optional pre-release part ("0.4.0", "v0.4.0", "1.0.0-beta.1"). Build metadata after "+"
/// is ignored. A pre-release sorts before the same version without one.
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preRelease: String?

    public init(major: Int, minor: Int, patch: Int, preRelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// nil when the text is not a version (a leading "v" is allowed, "0.4" is not: releases always have three parts).
    public init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") { raw.removeFirst() }
        if let plus = raw.firstIndex(of: "+") { raw = String(raw[..<plus]) }
        var pre: String?
        if let dash = raw.firstIndex(of: "-") {
            pre = String(raw[raw.index(after: dash)...])
            raw = String(raw[..<dash])
            guard let p = pre, !p.isEmpty else { return nil }
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], preRelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (preRelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.preRelease, b.preRelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return comparePreRelease(x, y)
        }
    }

    /// SemVer 2.0 §11: dot-separated identifiers, numbers compare numerically and sort before words.
    private static func comparePreRelease(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for (p, q) in zip(x, y) where p != q {
            switch (Int(p), Int(q)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            default: return p < q
            }
        }
        return x.count < y.count
    }
}

public struct ReleaseAsset: Equatable, Decodable {
    public let name: String
    public let downloadURL: URL
    public let size: Int

    public init(name: String, downloadURL: URL, size: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case name, size
        case downloadURL = "browser_download_url"
    }
}

/// The part of GitHub's `GET /repos/{owner}/{repo}/releases/latest` answer the updater uses.
public struct ReleaseInfo: Equatable, Decodable {
    public let tag: String
    public let name: String?
    public let body: String?
    public let pageURL: URL?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [ReleaseAsset]

    public init(tag: String, name: String?, body: String?, pageURL: URL?, draft: Bool, prerelease: Bool,
                assets: [ReleaseAsset]) {
        self.tag = tag
        self.name = name
        self.body = body
        self.pageURL = pageURL
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tag = "tag_name"
        case pageURL = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        pageURL = try? c.decodeIfPresent(URL.self, forKey: .pageURL)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        // One odd asset must not hide the others.
        let raw = (try? c.decodeIfPresent([FailableAsset].self, forKey: .assets)) ?? nil
        assets = (raw ?? []).compactMap { $0.asset }
    }

    private struct FailableAsset: Decodable {
        let asset: ReleaseAsset?
        init(from decoder: Decoder) throws { asset = try? ReleaseAsset(from: decoder) }
    }

    public var version: SemanticVersion? { SemanticVersion(tag) }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }
}

/// `SHA256SUMS.txt` as written by `shasum -a 256` / `sha256sum`: "<64 hex>  <file>" (text mode) or "<64 hex> *<file>"
/// (binary mode), one per line.
public enum SHA256Sums {
    public enum Problem: Error, Equatable {
        case malformedLine(Int)
        case duplicate(String)
    }

    /// File name → lowercase hex digest. Blank lines are skipped; any other line that is not a checksum line makes the
    /// whole file invalid, so a damaged file is never half-trusted.
    public static func parse(_ text: String) throws -> [String: String] {
        var sums: [String: String] = [:]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let chars = Array(line)
            guard chars.count > 66 else { throw Problem.malformedLine(index + 1) }
            let digest = String(chars[0..<64]).lowercased()
            guard digest.allSatisfy({ $0.isHexDigit }), chars[64] == " ", chars[65] == " " || chars[65] == "*" else {
                throw Problem.malformedLine(index + 1)
            }
            let name = String(chars[66...])
            guard !name.isEmpty, !name.contains("/") else { throw Problem.malformedLine(index + 1) }
            if sums[name] != nil { throw Problem.duplicate(name) }
            sums[name] = digest
        }
        return sums
    }
}

/// Picks what to download from a release and decides whether it is an update.
public enum UpdatePlan {
    public static let checksumsName = "SHA256SUMS.txt"

    /// The zip the release workflow builds: `NachoCombo-<version>-macos.zip`.
    public static func zipName(for version: SemanticVersion) -> String { "NachoCombo-\(version)-macos.zip" }

    public enum Decision: Equatable {
        /// This copy is the newest (or newer: a development build).
        case upToDate
        /// A newer release with both the zip and its checksums.
        case available(version: SemanticVersion, zip: ReleaseAsset, checksums: ReleaseAsset)
        /// Not something to offer (draft, pre-release, odd tag, missing files): ignored without bothering the user.
        case ignored(String)
    }

    public static func decide(current: String, release: ReleaseInfo) -> Decision {
        if release.draft { return .ignored("draft") }
        if release.prerelease { return .ignored("pre-release") }
        guard let latest = release.version, latest.preRelease == nil else { return .ignored("tag \(release.tag) is not a version") }
        guard let mine = SemanticVersion(current) else { return .ignored("this copy's version \(current) is not a version") }
        guard mine < latest else { return .upToDate }
        guard let zip = release.assets.first(where: { $0.name == zipName(for: latest) }) else {
            return .ignored("no \(zipName(for: latest)) in the release")
        }
        guard let sums = release.assets.first(where: { $0.name == checksumsName }) else {
            return .ignored("no \(checksumsName) in the release")
        }
        return .available(version: latest, zip: zip, checksums: sums)
    }

    public enum VerifyProblem: Error, Equatable {
        case badChecksumsFile
        case notListed(String)
        case mismatch(expected: String, actual: String)
    }

    /// The downloaded zip must be listed in the release's checksums with the same SHA-256, or nothing is installed.
    public static func verify(_ data: Data, name: String, checksums: String) -> VerifyProblem? {
        guard let sums = try? SHA256Sums.parse(checksums) else { return .badChecksumsFile }
        guard let expected = sums[name] else { return .notListed(name) }
        let actual = SHA256.hex(of: data)
        guard actual == expected else { return .mismatch(expected: expected, actual: actual) }
        return nil
    }

    /// The first few lines of the release notes as plain text (headings and list marks dropped), for a short summary.
    public static func summary(of body: String?, maxLines: Int = 4, maxLength: Int = 320) -> String {
        guard let body = body else { return "" }
        var lines: [String] = []
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) { line = "• " + line.dropFirst(mark.count) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line)
            if lines.count == maxLines { break }
        }
        let text = lines.joined(separator: "\n")
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    /// Automatic checks: at launch and then once a day.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public static func isCheckDue(last: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let last = last else { return true }
        // A clock set back must not stop checks for good.
        return now.timeIntervalSince(last) >= interval || now < last
    }
}
