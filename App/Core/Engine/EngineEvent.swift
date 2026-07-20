// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum EngineEvent: Decodable, Equatable, Sendable {
    case started(EnginePlanHeader)
    case candidate(EngineCandidate)
    case application(EngineApplication)
    case uninstallCandidate(EngineUninstallCandidate)
    case progress(completed: Int, total: Int)
    case itemResult(EngineItemResult)
    case permissionRequired(scope: PermissionScope)
    case completed(EngineCompletion)
    case failed(code: String, messageKey: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case operation
        case planID = "plan_id"
        case inventoryID = "inventory_id"
        case expiresAt = "expires_at"
        case id
        case name
        case path
        case size
        case category
        case risk
        case requiresRoot = "requires_root"
        case reversible
        case device
        case inode
        case modifiedAt = "modified_at"
        case bundleID = "bundle_id"
        case source
        case protected
        case defaultSelected = "default_selected"
        case completed
        case total
        case status
        case bytes
        case errorCode = "error_code"
        case scope
        case freedBytes = "freed_bytes"
        case candidateCount = "candidate_count"
        case failedCount = "failed_count"
        case code
        case messageKey = "message_key"
    }

    private enum EventType: String, Decodable {
        case started
        case candidate
        case application
        case uninstallCandidate = "uninstall_candidate"
        case progress
        case itemResult = "item_result"
        case permissionRequired = "permission_required"
        case completed
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .started:
            let expiresAtSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
            self = .started(
                EnginePlanHeader(
                    protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                    operation: try container.decode(String.self, forKey: .operation),
                    planID: try container.decodeIfPresent(String.self, forKey: .planID),
                    expiresAt: expiresAtSeconds.map(Date.init(timeIntervalSince1970:))
                )
            )
        case .candidate:
            self = .candidate(
                EngineCandidate(
                    planID: try container.decodeIfPresent(String.self, forKey: .planID),
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decodeIfPresent(String.self, forKey: .name),
                    path: try container.decodeIfPresent(String.self, forKey: .path),
                    size: try container.decode(Int64.self, forKey: .size),
                    category: try container.decode(String.self, forKey: .category),
                    risk: try container.decodeIfPresent(String.self, forKey: .risk),
                    requiresRoot: try container.decode(Bool.self, forKey: .requiresRoot),
                    reversible: try container.decode(Bool.self, forKey: .reversible),
                    device: try container.decodeIfPresent(UInt64.self, forKey: .device),
                    inode: try container.decodeIfPresent(UInt64.self, forKey: .inode),
                    modifiedAt: try container.decodeIfPresent(Int64.self, forKey: .modifiedAt)
                )
            )
        case .application:
            self = .application(
                EngineApplication(
                    inventoryID: try container.decode(String.self, forKey: .inventoryID),
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    path: try container.decode(String.self, forKey: .path),
                    bundleID: try container.decode(String.self, forKey: .bundleID),
                    size: try container.decode(Int64.self, forKey: .size),
                    source: try container.decode(String.self, forKey: .source),
                    isProtected: try container.decode(Bool.self, forKey: .protected),
                    device: try container.decode(UInt64.self, forKey: .device),
                    inode: try container.decode(UInt64.self, forKey: .inode),
                    modifiedAt: try container.decode(Int64.self, forKey: .modifiedAt)
                )
            )
        case .uninstallCandidate:
            self = .uninstallCandidate(
                EngineUninstallCandidate(
                    planID: try container.decode(String.self, forKey: .planID),
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    path: try container.decode(String.self, forKey: .path),
                    size: try container.decode(Int64.self, forKey: .size),
                    category: try container.decode(String.self, forKey: .category),
                    risk: try container.decode(String.self, forKey: .risk),
                    defaultSelected: try container.decode(Bool.self, forKey: .defaultSelected),
                    requiresRoot: try container.decode(Bool.self, forKey: .requiresRoot),
                    reversible: try container.decode(Bool.self, forKey: .reversible),
                    device: try container.decode(UInt64.self, forKey: .device),
                    inode: try container.decode(UInt64.self, forKey: .inode),
                    modifiedAt: try container.decode(Int64.self, forKey: .modifiedAt)
                )
            )
        case .progress:
            self = .progress(
                completed: try container.decode(Int.self, forKey: .completed),
                total: try container.decode(Int.self, forKey: .total)
            )
        case .itemResult:
            self = .itemResult(
                EngineItemResult(
                    planID: try container.decode(String.self, forKey: .planID),
                    id: try container.decode(String.self, forKey: .id),
                    status: try container.decode(String.self, forKey: .status),
                    bytes: try container.decode(Int64.self, forKey: .bytes),
                    errorCode: try container.decodeIfPresent(String.self, forKey: .errorCode)
                )
            )
        case .permissionRequired:
            self = .permissionRequired(scope: try container.decode(PermissionScope.self, forKey: .scope))
        case .completed:
            self = .completed(
                EngineCompletion(
                    planID: try container.decodeIfPresent(String.self, forKey: .planID),
                    freedBytes: try container.decode(Int64.self, forKey: .freedBytes),
                    candidateCount: try container.decodeIfPresent(Int.self, forKey: .candidateCount),
                    failedCount: try container.decodeIfPresent(Int.self, forKey: .failedCount)
                )
            )
        case .failed:
            self = .failed(
                code: try container.decode(String.self, forKey: .code),
                messageKey: try container.decode(String.self, forKey: .messageKey)
            )
        }
    }
}

struct EnginePlanHeader: Equatable, Sendable {
    let protocolVersion: Int
    let operation: String
    let planID: String?
    let expiresAt: Date?
}

struct EngineCandidate: Equatable, Sendable {
    let planID: String?
    let id: String
    let name: String?
    let path: String?
    let size: Int64
    let category: String
    let risk: String?
    let requiresRoot: Bool
    let reversible: Bool
    let device: UInt64?
    let inode: UInt64?
    let modifiedAt: Int64?

    init(
        planID: String? = nil,
        id: String,
        name: String? = nil,
        path: String? = nil,
        size: Int64,
        category: String,
        risk: String? = nil,
        requiresRoot: Bool,
        reversible: Bool,
        device: UInt64? = nil,
        inode: UInt64? = nil,
        modifiedAt: Int64? = nil
    ) {
        self.planID = planID
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.category = category
        self.risk = risk
        self.requiresRoot = requiresRoot
        self.reversible = reversible
        self.device = device
        self.inode = inode
        self.modifiedAt = modifiedAt
    }
}

struct EngineApplication: Equatable, Sendable {
    let inventoryID: String
    let id: String
    let name: String
    let path: String
    let bundleID: String
    let size: Int64
    let source: String
    let isProtected: Bool
    let device: UInt64
    let inode: UInt64
    let modifiedAt: Int64
}

struct EngineUninstallCandidate: Equatable, Sendable {
    let planID: String
    let id: String
    let name: String
    let path: String
    let size: Int64
    let category: String
    let risk: String
    let defaultSelected: Bool
    let requiresRoot: Bool
    let reversible: Bool
    let device: UInt64
    let inode: UInt64
    let modifiedAt: Int64
}

struct EngineCompletion: Equatable, Sendable {
    let planID: String?
    let freedBytes: Int64
    let candidateCount: Int?
    let failedCount: Int?
}

struct EngineItemResult: Equatable, Sendable {
    let planID: String
    let id: String
    let status: String
    let bytes: Int64
    let errorCode: String?
}

enum PermissionScope: String, Decodable, Sendable {
    case fullDiskAccess = "full_disk_access"
    case administrator
}
