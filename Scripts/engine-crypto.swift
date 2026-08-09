#!/usr/bin/env xcrun swift
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

private enum ToolError: Error, CustomStringConvertible {
    case usage
    case invalidBase64(String)
    case verificationFailed

    var description: String {
        switch self {
        case .usage:
            return "usage: engine-crypto.swift generate PRIVATE_KEY_PATH | sign PRIVATE_KEY_PATH MANIFEST_PATH SIGNATURE_PATH | verify PUBLIC_KEY_BASE64 MANIFEST_PATH SIGNATURE_PATH"
        case let .invalidBase64(name):
            return "invalid base64 data: \(name)"
        case .verificationFailed:
            return "manifest signature verification failed"
        }
    }
}

private func decodedBase64File(at path: String, name: String) throws -> Data {
    let text = try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: text) else {
        throw ToolError.invalidBase64(name)
    }
    return data
}

private func writePrivateKey(_ key: Curve25519.Signing.PrivateKey, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let data = Data(key.rawRepresentation.base64EncodedString().utf8)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ToolError.usage }

    switch command {
    case "generate":
        guard arguments.count == 2 else { throw ToolError.usage }
        let key = Curve25519.Signing.PrivateKey()
        try writePrivateKey(key, to: arguments[1])
        print(key.publicKey.rawRepresentation.base64EncodedString())

    case "sign":
        guard arguments.count == 4 else { throw ToolError.usage }
        let privateData = try decodedBase64File(at: arguments[1], name: "private key")
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
        let manifest = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let signature = try privateKey.signature(for: manifest)
        let encoded = Data((signature.base64EncodedString() + "\n").utf8)
        try encoded.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)

    case "verify":
        guard arguments.count == 4,
              let publicData = Data(base64Encoded: arguments[1]) else {
            throw arguments.count == 4 ? ToolError.invalidBase64("public key") : ToolError.usage
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        let manifest = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let signature = try decodedBase64File(at: arguments[3], name: "signature")
        guard publicKey.isValidSignature(signature, for: manifest) else {
            throw ToolError.verificationFailed
        }

    default:
        throw ToolError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("engine-crypto: \(error)\n".utf8))
    exit(1)
}
