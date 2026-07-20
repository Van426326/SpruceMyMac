// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Darwin

private func printSelfTestManifest() {
    let tasks = SystemMaintenanceTaskCatalog.taskIdentifiers
        .map { "\"\($0)\"" }
        .joined(separator: ",")
    print(
        "{\"protocol\":\(SprucePrivilegedHelperConstants.protocolVersion)," +
        "\"service\":\"\(SprucePrivilegedHelperConstants.serviceIdentifier)\"," +
        "\"tasks\":[\(tasks)],\"fixed_commands\":true}"
    )
}

private func containingApplicationURL() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for _ in 0..<4 {
        url.deleteLastPathComponent()
    }
    guard url.pathExtension == "app",
          Bundle(url: url)?.bundleIdentifier == SprucePrivilegedHelperConstants.applicationIdentifier else {
        return nil
    }
    return url
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--self-test" {
    printSelfTestManifest()
    exit(0)
}

guard CommandLine.arguments.count == 1 else {
    fputs("sprucemymac-helper accepts no command-line tasks\n", stderr)
    exit(EX_USAGE)
}

guard geteuid() == 0 else {
    fputs("sprucemymac-helper must be launched by the registered system service\n", stderr)
    exit(EX_NOPERM)
}

guard let applicationURL = containingApplicationURL() else {
    fputs("unable to locate the containing SpruceMyMac application\n", stderr)
    exit(EX_CONFIG)
}

do {
    let applicationRequirement = try CodeSigningRequirementReader.designatedRequirement(for: applicationURL)
    let delegate = PrivilegedHelperListenerDelegate()
    let listener = NSXPCListener(machServiceName: SprucePrivilegedHelperConstants.serviceIdentifier)
    listener.setConnectionCodeSigningRequirement(applicationRequirement)
    listener.delegate = delegate
    listener.activate()
    dispatchMain()
} catch {
    fputs("unable to establish signed XPC listener: \(error.localizedDescription)\n", stderr)
    exit(EX_CONFIG)
}
