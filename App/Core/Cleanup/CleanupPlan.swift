// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct CleanupPlan: Identifiable, Sendable {
    let id: UUID
    let enginePlanID: String?
    let createdAt: Date
    let expiresAt: Date
    let candidates: [Candidate]

    var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.size }
    }

    init(
        candidates: [CleanupCandidate],
        now: Date = Date(),
        lifetime: TimeInterval = 15 * 60,
        enginePlanID: String? = nil,
        engineExpiresAt: Date? = nil
    ) {
        id = UUID()
        self.enginePlanID = enginePlanID
        createdAt = now
        let localExpiry = now.addingTimeInterval(lifetime)
        expiresAt = min(engineExpiresAt ?? localExpiry, localExpiry)
        self.candidates = candidates.map(Candidate.init)
    }

    struct Candidate: Identifiable, Sendable {
        let id: String
        let name: String
        let path: String
        let size: Int64
        let category: CleanupCandidate.Category
        let risk: CleanupCandidate.Risk
        let fingerprint: FileFingerprint

        init(_ candidate: CleanupCandidate) {
            id = candidate.id
            name = candidate.name
            path = candidate.path
            size = candidate.size
            category = candidate.category
            risk = candidate.risk
            fingerprint = candidate.fingerprint
        }
    }
}

actor CleanupPlanValidator {
    enum ValidationError: Error, Equatable, Sendable {
        case expired
        case empty
        case duplicateCandidate
        case pathOutsideAllowedRoot
        case pathChanged
    }

    private let allowedRoot: URL

    init(allowedRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches", isDirectory: true)) {
        self.allowedRoot = allowedRoot
    }

    func validate(_ plan: CleanupPlan, now: Date = Date()) -> Result<Void, ValidationError> {
        guard plan.expiresAt > now else { return .failure(.expired) }
        guard !plan.candidates.isEmpty else { return .failure(.empty) }

        let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        var seenIDs = Set<String>()

        for candidate in plan.candidates {
            guard seenIDs.insert(candidate.id).inserted else {
                return .failure(.duplicateCandidate)
            }

            let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(root + "/") else {
                return .failure(.pathOutsideAllowedRoot)
            }

            guard FileFingerprint.capture(at: url) == candidate.fingerprint else {
                return .failure(.pathChanged)
            }
        }

        return .success(())
    }
}
