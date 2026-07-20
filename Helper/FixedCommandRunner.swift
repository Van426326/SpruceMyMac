// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import Foundation
import Darwin

struct FixedCommandExecution: Sendable {
    let exitCode: Int32
    let timedOut: Bool
}

final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

struct FixedCommandRunner {
    func execute(_ command: FixedSystemCommand) throws -> FixedCommandExecution {
        guard command.executablePath.hasPrefix("/usr/bin/"),
              !command.executablePath.contains(".."),
              FileManager.default.isExecutableFile(atPath: command.executablePath) else {
            throw HelperServiceError.commandUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/root",
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": "/private/tmp"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        let box = ProcessBox(process)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.process.waitUntilExit()
            finished.signal()
        }

        if finished.wait(timeout: .now() + .seconds(command.timeoutSeconds)) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(1))
            }
            let exitCode = process.isRunning ? -1 : process.terminationStatus
            return FixedCommandExecution(exitCode: exitCode, timedOut: true)
        }

        return FixedCommandExecution(exitCode: process.terminationStatus, timedOut: false)
    }
}

enum HelperServiceError: Int, LocalizedError {
    case invalidTask = 1
    case invalidRequestIdentifier = 2
    case replayedRequest = 3
    case helperNotPrivileged = 4
    case commandUnavailable = 5
    case commandTimedOut = 6
    case commandFailed = 7

    static let domain = "com.van426326.sprucemymac.helper"

    var errorDescription: String? {
        switch self {
        case .invalidTask: "Unknown maintenance task"
        case .invalidRequestIdentifier: "Invalid request identifier"
        case .replayedRequest: "Request identifier has already been used"
        case .helperNotPrivileged: "Helper is not running with root privileges"
        case .commandUnavailable: "Fixed system command is unavailable"
        case .commandTimedOut: "Fixed system command timed out"
        case .commandFailed: "Fixed system command failed"
        }
    }

    var nsError: NSError {
        NSError(
            domain: Self.domain,
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: errorDescription ?? "Helper error"]
        )
    }
}
