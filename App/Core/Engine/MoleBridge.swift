// SPDX-License-Identifier: GPL-3.0-only

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

    private let executableURL: URL?
    private var runningProcess: ProcessBox?

    init(bundle: Bundle = .main) {
        let launcher = bundle.url(
            forResource: "sprucemymac-engine",
            withExtension: nil,
            subdirectory: "Engine"
        )
        let overlayCommand = bundle.url(
            forResource: "gui",
            withExtension: "sh",
            subdirectory: "Engine/Mole/bin"
        )
#if DEBUG
        let developmentPath = ProcessInfo.processInfo.environment["SPRUCE_ENGINE_PATH"]
            .map(URL.init(fileURLWithPath:))
#else
        let developmentPath: URL? = nil
#endif
        executableURL = launcher ?? overlayCommand ?? developmentPath
    }

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func isAvailable() -> Bool {
        guard let executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func cleanPlanEvents() async throws -> [EngineEvent] {
        try await execute(
            arguments: ["clean-plan", "--format", "ndjson", "--no-auth"],
            expectedOperation: "clean",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true
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
            useTestAuthorizationGuard: false
        )
    }

    func applicationListEvents() async throws -> [EngineEvent] {
        try await execute(
            arguments: ["app-list", "--format", "ndjson", "--no-auth"],
            expectedOperation: "app_list",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true
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
            useTestAuthorizationGuard: true
        )
    }

    func toolPlanEvents(tool: ToolboxEngineTool) async throws -> [EngineEvent] {
        try await execute(
            arguments: ["tool-plan", "--tool", tool.rawValue, "--format", "ndjson", "--no-auth"],
            expectedOperation: "tool_plan",
            expectedPlanID: nil,
            useTestAuthorizationGuard: true
        )
    }

    private func execute(
        arguments: [String],
        expectedOperation: String,
        expectedPlanID: String?,
        useTestAuthorizationGuard: Bool
    ) async throws -> [EngineEvent] {
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw EngineProtocolError.executableUnavailable
        }

        let output = try await withTaskCancellationHandler {
            try await run(
                executableURL: executableURL,
                arguments: arguments,
                useTestAuthorizationGuard: useTestAuthorizationGuard
            )
        } onCancel: {
            Task { await self.cancelRunningProcess() }
        }
        try Task.checkCancellation()
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

    private func run(
        executableURL: URL,
        arguments: [String],
        useTestAuthorizationGuard: Bool
    ) async throws -> ProcessOutput {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        if useTestAuthorizationGuard {
            environment["MOLE_TEST_NO_AUTH"] = "1"
        } else {
            environment.removeValue(forKey: "MOLE_TEST_NO_AUTH")
        }
        process.environment = environment

        let processBox = ProcessBox(process)
        runningProcess = processBox
        defer { runningProcess = nil }

        try process.run()
        return await Task.detached(priority: .userInitiated) {
            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            processBox.process.waitUntilExit()

            return ProcessOutput(
                exitCode: processBox.process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: errorData
            )
        }.value
    }

    private func cancelRunningProcess() {
        guard let process = runningProcess?.process, process.isRunning else { return }
        process.terminate()
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
