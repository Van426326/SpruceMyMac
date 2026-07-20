// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct ProtectionRule: Identifiable, Hashable, Sendable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
actor ProtectionRuleStore {
    static let shared = ProtectionRuleStore()

    static let builtInRules = [
        "/System",
        "/Library/Apple",
        "~/Library/Keychains",
        "~/Library/Mobile Documents",
        "Apple 与系统应用"
    ]

    enum RuleError: Error, Equatable {
        case invalidPath
        case symbolicLink
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpruceMyMac", isDirectory: true),
        fileManager: FileManager = FileManager()
    ) {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent("whitelist")
        self.fileManager = fileManager
    }

    func rules() -> [ProtectionRule] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map(ProtectionRule.init(path:))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func add(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/"), standardized.path != "/" else {
            throw RuleError.invalidPath
        }
        guard (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw RuleError.symbolicLink
        }

        var paths = Set(rules().map(\.path))
        paths.insert(standardized.path)
        try write(paths.sorted())
    }

    func remove(_ rule: ProtectionRule) throws {
        let paths = rules().map(\.path).filter { $0 != rule.path }
        try write(paths)
    }

    func removeAll() throws {
        try write([])
    }

    func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return rules().contains { rule in
            path == rule.path || path.hasPrefix(rule.path + "/")
        }
    }

    private func write(_ paths: [String]) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let contents = paths.isEmpty ? "" : paths.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
