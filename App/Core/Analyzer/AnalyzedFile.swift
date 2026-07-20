// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct AnalyzedFile: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case video
        case archive
        case installer
        case document
        case other

        var title: String {
            switch self {
            case .video: String(localized: "视频")
            case .archive: String(localized: "压缩包")
            case .installer: String(localized: "安装包")
            case .document: String(localized: "文档")
            case .other: String(localized: "其他")
            }
        }

        var systemImage: String {
            switch self {
            case .video: "film"
            case .archive: "archivebox"
            case .installer: "shippingbox"
            case .document: "doc"
            case .other: "doc.questionmark"
            }
        }
    }

    let id: String
    let url: URL
    let size: Int64
    let modifiedAt: Date
    let category: Category
    let fingerprint: FileFingerprint

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var isOld: Bool { modifiedAt < Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast }
    var isInstaller: Bool { category == .installer }

    static func category(for url: URL) -> Category {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "avi", "m4v": .video
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": .archive
        case "dmg", "pkg", "mpkg", "iso": .installer
        case "pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx": .document
        default: .other
        }
    }
}
