import Foundation
import LocalAuthentication
import Security

private func emitJSON(_ value: [String: Any], exitCode: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    Foundation.exit(exitCode)
}

private func baseQuery(service: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "Jarvis",
    ]
}

private func biometricAccessControl() -> SecAccessControl? {
    var error: Unmanaged<CFError>?
    let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &error
    )
    error?.release()
    return access
}

@main
private struct JarvisKeychain {
    static func main() {
        guard CommandLine.arguments.count >= 3 else {
            emitJSON(["ok": false, "error": "usage"], exitCode: 64)
        }
        let command = CommandLine.arguments[1]
        let service = CommandLine.arguments[2]
        guard service.hasPrefix("dev.pbbuilds.jarvis."),
              service.count <= 96 else {
            emitJSON(["ok": false, "error": "invalid_service"], exitCode: 64)
        }

        switch command {
        case "set", "set-biometric":
            let value = FileHandle.standardInput.readDataToEndOfFile()
            guard !value.isEmpty else {
                emitJSON(["ok": false, "error": "empty_secret"], exitCode: 64)
            }
            let query = baseQuery(service: service)
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = value
            if command == "set-biometric" {
                guard let access = biometricAccessControl() else {
                    emitJSON(["ok": false, "error": "biometry_unavailable"], exitCode: 70)
                }
                item[kSecAttrAccessControl as String] = access
            } else {
                item[kSecAttrAccessible as String] =
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else {
                emitJSON(
                    ["ok": false, "error": "keychain_status_\(status)"],
                    exitCode: 70
                )
            }
            emitJSON(["ok": true])
        case "get", "get-biometric":
            var query = baseQuery(service: service)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if command == "get-biometric" {
                let context = LAContext()
                context.localizedCancelTitle = "Cancel"
                context.localizedReason =
                    "Use Touch ID to release this Jarvis credential."
                query[kSecUseAuthenticationContext as String] = context
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                emitJSON(["ok": false, "found": false], exitCode: 44)
            }
            FileHandle.standardOutput.write(data)
            Foundation.exit(0)
        case "status":
            var query = baseQuery(service: service)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            emitJSON(["ok": true, "found": status == errSecSuccess])
        case "delete":
            let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
            emitJSON([
                "ok": status == errSecSuccess || status == errSecItemNotFound,
                "deleted": status == errSecSuccess,
            ])
        default:
            emitJSON(["ok": false, "error": "unsupported_command"], exitCode: 64)
        }
    }
}
