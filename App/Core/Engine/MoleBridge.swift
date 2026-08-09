// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Defines the stable boundary between the native UI and the bundled engine.
/// The executable is intentionally not invoked until the fork exposes the
/// versioned NDJSON contract represented by `EngineEvent`.
protocol CleaningEngine: Sendable {
    func isAvailable() async -> Bool
    func cleanPlanEvents() async throws -> [EngineEvent]
    func applicationListEvents() async throws -> [EngineEvent]
    func uninstallPlanEvents(inventoryID: String, applicationID: String) async throws -> [EngineEvent]
    func toolPlanEvents(tool: ToolboxEngineTool) async throws -> [EngineEvent]
    func applyPlanEvents(planID: String, candidateIDs: [String]) async throws -> [EngineEvent]
}

enum ToolboxEngineTool: String, Sendable {
    case developer
    case installers
}

actor BundledMoleBridge: CleaningEngine {
    static let supportedProtocolVersion = 1

    private enum ExecutableSource: Sendable {
        case fixed(URL)
        case resolved(any EngineResolving)
    }

    private let executableSource: ExecutableSource
    private var runningProcesses: [UUID: ProcessBox] = [:]
    private var activeOperationIDs: Set<UUID> = []
    private var pendingCancellations: Set<UUID> = []

    init() {
#if DEBUG
        if let developmentPath = ProcessInfo.processInfo.environment["SPRUCE_ENGINE_PATH"],
           !developmentPath.isEmpty {
            executableSource = .fixed(URL(fileURLWithPath: developmentPath))
        } else {
            executableSource = .resolved(EngineUpdateRuntime.resolver)
        }
#else
        executableSource = .resolved(EngineUpdateRuntime.resolver)
#endif
    }

    init(executableURL: URL) {
        executableSource = .fixed(executableURL)
    }

    init(resolver: any EngineResolving) {
        executableSource = .resolved(resolver)
    }

    func isAvailable() async -> Bool {
        guard let executableURL = try? await resolveExecutableURL() else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func cleanPlanEvents() async throws -> [EngineEvent] {
        try await execute(
            arguments: ["clean-plan", "--format", "ndjson", "--no-auth"],
            expectedOperation: "clean",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true,
            permitsCancellation: true
        )
    }

    func applyPlanEvents(planID: String, candidateIDs: [String]) async throws -> [EngineEvent] {
        guard UUID(uuidString: planID) != nil,
              !candidateIDs.isEmpty,
              candidateIDs.count <= 500,
              candidateIDs.allSatisfy(Self.isValidCandidateID),
              Set(candidateIDs).count == candidateIDs.count else {
            throw EngineProtocolError.invalidRequest
        }

        return try await execute(
            arguments: [
                "apply-plan",
                "--plan-id", planID.lowercased(),
                "--items", candidateIDs.joined(separator: ","),
                "--format", "ndjson",
                "--no-auth"
            ],
            expectedOperation: "apply_clean",
            expectedPlanID: planID.lowercased(),
            useTestAuthorizationGuard: false,
            permitsCancellation: false
        )
    }

    func applicationListEvents() async throws -> [EngineEvent] {
        try await execute(
            arguments: ["app-list", "--format", "ndjson", "--no-auth"],
            expectedOperation: "app_list",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true,
            permitsCancellation: true
        )
    }

    func uninstallPlanEvents(inventoryID: String, applicationID: String) async throws -> [EngineEvent] {
        guard UUID(uuidString: inventoryID) != nil,
              Self.isValidCandidateID(applicationID) else {
            throw EngineProtocolError.invalidRequest
        }
        return try await execute(
            arguments: [
                "uninstall-plan",
                "--inventory-id", inventoryID.lowercased(),
                "--app-id", applicationID,
                "--format", "ndjson",
                "--no-auth"
            ],
            expectedOperation: "uninstall_plan",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true,
            permitsCancellation: true
        )
    }

    func toolPlanEvents(tool: ToolboxEngineTool) async throws -> [EngineEvent] {
        try await execute(
            arguments: ["tool-plan", "--tool", tool.rawValue, "--format", "ndjson", "--no-auth"],
            expectedOperation: "tool_plan",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true,
            permitsCancellation: true
        )
    }

    private func execute(
        arguments: [String],
        expectedOperation: String,
        expectedPlanID: String?,
        useTestAuthorizationGuard: Bool,
        permitsCancellation: Bool
    ) async throws -> [EngineEvent] {
        let executableURL: URL
        do {
            executableURL = try await resolveExecutableURL()
        } catch {
            throw EngineProtocolError.executableUnavailable
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw EngineProtocolError.executableUnavailable
        }

        let operationID = UUID()
        activeOperationIDs.insert(operationID)
        defer {
            activeOperationIDs.remove(operationID)
            pendingCancellations.remove(operationID)
        }
        let output = try await withTaskCancellationHandler {
            try await run(
                executableURL: executableURL,
                arguments: arguments,
                useTestAuthorizationGuard: useTestAuthorizationGuard,
                operationID: operationID
            )
        } onCancel: {
            guard permitsCancellation else { return }
            Task { await self.cancelRunningProcess(operationID: operationID) }
        }
        if permitsCancellation {
            try Task.checkCancellation()
        }
        let decoder = NDJSONEventDecoder()
        let events = try output.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(line: String($0)) }

        if let failureCode = events.compactMap({ event -> String? in
            guard case let .failed(code, _) = event else { return nil }
            return code
        }).first {
            throw EngineProtocolError.engineFailure(failureCode)
        }

        let headers = events.compactMap({ event -> EnginePlanHeader? in
            guard case let .started(header) = event else { return nil }
            return header
        })
        let completions = events.compactMap({ event -> EngineCompletion? in
            guard case let .completed(completion) = event else { return nil }
            return completion
        })

        guard headers.count == 1, completions.count == 1 else {
            throw EngineProtocolError.invalidEventSequence
        }

        let header = headers[0]
        let completion = completions[0]
        if header.protocolVersion != Self.supportedProtocolVersion {
            throw EngineProtocolError.unsupportedProtocol(header.protocolVersion)
        }
        guard header.operation == expectedOperation else {
            throw EngineProtocolError.invalidEventSequence
        }

        if let expectedPlanID, header.planID != expectedPlanID {
            throw EngineProtocolError.invalidEventSequence
        }

        if let planID = header.planID,
           (completion.planID != planID || events.contains(where: { event in
               switch event {
               case let .candidate(candidate):
                   return candidate.planID != planID
               case let .application(application):
                   return application.inventoryID != planID
               case let .uninstallCandidate(candidate):
                   return candidate.planID != planID
               case let .itemResult(result):
                   return result.planID != planID
               default:
                   return false
               }
           })) {
            throw EngineProtocolError.invalidEventSequence
        }

        if output.exitCode != 0,
           !events.contains(where: { event in
               if case .failed = event { return true }
               return false
           }) {
            throw EngineProtocolError.processFailed(
                output.exitCode,
                String(decoding: output.standardError, as: UTF8.self)
            )
        }

        return events
    }

    private func resolveExecutableURL() async throws -> URL {
        switch executableSource {
        case let .fixed(url):
            return url
        case let .resolved(resolver):
            return try await resolver.resolve().executableURL
        }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        useTestAuthorizationGuard: Bool,
        operationID: UUID
    ) async throws -> ProcessOutput {
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpruceBridge-\(operationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let standardOutput = try FileHandle(forWritingTo: outputURL)
        let standardError = try FileHandle(forWritingTo: errorURL)

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in completion.signal() }
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        if useTestAuthorizationGuard {
            environment["MOLE_TEST_NO_AUTH"] = "1"
        } else {
            environment.removeValue(forKey: "MOLE_TEST_NO_AUTH")
        }
        process.environment = environment

        let processBox = ProcessBox(process)
        runningProcesses[operationID] = processBox
        defer { runningProcesses.removeValue(forKey: operationID) }

        do {
            try process.run()
            if pendingCancellations.remove(operationID) != nil {
                requestTermination(of: processBox)
            }
        } catch {
            try? standardOutput.close()
            try? standardError.close()
            throw error
        }
        return try await Task.detached(priority: .userInitiated) {
            Self.waitForProcessCompletion(completion)
            try standardOutput.close()
            try standardError.close()
            let maximumCapture = 16 * 1024 * 1024
            let outputSize = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try FileManager.default.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard outputSize <= maximumCapture, errorSize <= maximumCapture else {
                throw EngineProtocolError.invalidEventSequence
            }
            return ProcessOutput(
                exitCode: processBox.process.terminationStatus,
                standardOutput: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                standardError: try Data(contentsOf: errorURL)
            )
        }.value
    }

    private func cancelRunningProcess(operationID: UUID) {
        guard activeOperationIDs.contains(operationID) else { return }
        guard let processBox = runningProcesses[operationID] else {
            pendingCancellations.insert(operationID)
            return
        }
        requestTermination(of: processBox)
    }

    private func requestTermination(of processBox: ProcessBox) {
        guard processBox.process.isRunning else { return }
        processBox.process.terminate()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard processBox.process.isRunning else { return }
            kill(processBox.process.processIdentifier, SIGKILL)
        }
    }

    private nonisolated static func waitForProcessCompletion(_ completion: DispatchSemaphore) {
        completion.wait()
    }

    private nonisolated static func isValidCandidateID(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private struct ProcessOutput: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: Data
}
