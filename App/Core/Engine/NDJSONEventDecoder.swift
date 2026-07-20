// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct NDJSONEventDecoder: Sendable {
    private let decoder = JSONDecoder()

    func decode(line: String) throws -> EngineEvent {
        guard let data = line.data(using: .utf8) else {
            throw EngineProtocolError.invalidUTF8
        }
        return try decoder.decode(EngineEvent.self, from: data)
    }
}

enum EngineProtocolError: Error, Equatable {
    case invalidUTF8
    case executableUnavailable
    case unsupportedProtocol(Int)
    case processFailed(Int32, String)
    case invalidEventSequence
    case invalidRequest
    case engineFailure(String)
}
