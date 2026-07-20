// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import Foundation
import Darwin
import OSLog

final class HelperReplyBox: @unchecked Sendable {
    private let reply: (NSDictionary?, NSError?) -> Void

    init(_ reply: @escaping (NSDictionary?, NSError?) -> Void) {
        self.reply = reply
    }

    func callAsFunction(_ dictionary: NSDictionary?, _ error: NSError?) {
        reply(dictionary, error)
    }
}

final class PrivilegedHelperService: NSObject, SprucePrivilegedHelperProtocol, @unchecked Sendable {
    private let executionQueue = DispatchQueue(label: "com.van426326.sprucemymac.helper.execution")
    private let runner = FixedCommandRunner()
    private let logger = Logger(
        subsystem: SprucePrivilegedHelperConstants.serviceIdentifier,
        category: "maintenance"
    )
    private var recentRequestIdentifiers: [String] = []
    private var recentRequestSet: Set<String> = []

    func helperVersion(withReply reply: @escaping (Int) -> Void) {
        reply(SprucePrivilegedHelperConstants.protocolVersion)
    }

    func availableTaskIdentifiers(withReply reply: @escaping ([String]) -> Void) {
        reply(SystemMaintenanceTaskCatalog.taskIdentifiers)
    }

    func runTask(
        _ taskIdentifier: String,
        requestIdentifier: String,
        withReply reply: @escaping (NSDictionary?, NSError?) -> Void
    ) {
        guard geteuid() == 0 else {
            reply(nil, HelperServiceError.helperNotPrivileged.nsError)
            return
        }
        guard let canonicalRequestID = PrivilegedRequestValidator.canonicalRequestIdentifier(requestIdentifier) else {
            reply(nil, HelperServiceError.invalidRequestIdentifier.nsError)
            return
        }
        guard let definition = PrivilegedRequestValidator.task(for: taskIdentifier) else {
            reply(nil, HelperServiceError.invalidTask.nsError)
            return
        }

        let replyBox = HelperReplyBox(reply)
        executionQueue.async { [self] in
            guard rememberRequest(canonicalRequestID) else {
                replyBox(nil, HelperServiceError.replayedRequest.nsError)
                return
            }

            let startedAt = Date()
            logger.notice("Starting fixed maintenance task \(definition.task.rawValue, privacy: .public)")
            var exitCodes: [NSNumber] = []
            var resultError: HelperServiceError?

            for command in definition.commands {
                do {
                    let execution = try runner.execute(command)
                    exitCodes.append(NSNumber(value: execution.exitCode))
                    if execution.timedOut {
                        resultError = .commandTimedOut
                        break
                    }
                    if execution.exitCode != 0 {
                        resultError = .commandFailed
                        break
                    }
                } catch {
                    resultError = .commandUnavailable
                    break
                }
            }

            let succeeded = resultError == nil
            let finishedAt = Date()
            let response: NSDictionary = [
                "protocol": SprucePrivilegedHelperConstants.protocolVersion,
                "request_id": canonicalRequestID,
                "task_id": definition.task.rawValue,
                "succeeded": succeeded,
                "started_at": startedAt.timeIntervalSince1970,
                "finished_at": finishedAt.timeIntervalSince1970,
                "exit_codes": exitCodes,
                "message_key": succeeded ? "helper.task.completed" : "helper.task.failed"
            ]
            logger.notice("Finished fixed maintenance task \(definition.task.rawValue, privacy: .public), success: \(succeeded)")
            replyBox(response, resultError?.nsError)
        }
    }

    private func rememberRequest(_ identifier: String) -> Bool {
        guard recentRequestSet.insert(identifier).inserted else { return false }
        recentRequestIdentifiers.append(identifier)
        if recentRequestIdentifiers.count > 128 {
            let removed = recentRequestIdentifiers.removeFirst()
            recentRequestSet.remove(removed)
        }
        return true
    }
}

final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SprucePrivilegedHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.activate()
        return true
    }
}
