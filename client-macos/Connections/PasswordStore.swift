import Foundation
import Security

/// Whose password: the computer's, or that of the RD Gateway in front of it
enum PasswordKind: Sendable, CaseIterable {
    case server, gateway
}

/// Where the passwords of the profiles live: one of each kind per profile id
@MainActor
protocol PasswordStore: AnyObject {
    func password(for id: UUID, kind: PasswordKind) -> String?
    /// Whether a password is saved, read without its secret, so macOS asks nobody for access
    func hasPassword(for id: UUID, kind: PasswordKind) -> Bool
    /// The label is what Keychain Access shows; errSecSuccess, or why the store refused the password
    func setPassword(_ password: String, for id: UUID, kind: PasswordKind, label: String) -> OSStatus
    func deletePassword(for id: UUID, kind: PasswordKind)
}

/// The passwords in the login keychain, as generic passwords of the app's service
/// The account is the profile id, with a suffix for the gateway password
///
/// The data protection keychain would need a signed application identifier, and the ad-hoc signed app has none:
/// the file-based keychain grants the item to the app that saved it, and macOS asks the user
/// before another build of the app reads it
@MainActor
final class KeychainPasswordStore: PasswordStore {
    static let standardService = "tech.vibebrains.viberdp.connection"

    let service: String

    init(service: String = standardService) {
        self.service = service
    }

    func password(for id: UUID, kind: PasswordKind) -> String? {
        var query = self.query(for: id, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for id: UUID, kind: PasswordKind) -> Bool {
        var query = self.query(for: id, kind: kind)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setPassword(_ password: String, for id: UUID, kind: PasswordKind, label: String) -> OSStatus {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(query(for: id, kind: kind) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }

        var item = query(for: id, kind: kind)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        return SecItemAdd(item as CFDictionary, nil)
    }

    func deletePassword(for id: UUID, kind: PasswordKind) {
        _ = SecItemDelete(query(for: id, kind: kind) as CFDictionary)
    }

    /// The computer's password under the bare id, the gateway's under the id with a suffix
    static func account(for id: UUID, kind: PasswordKind) -> String {
        switch kind {
        case .server: id.uuidString
        case .gateway: "\(id.uuidString).gateway"
        }
    }

    private func query(for id: UUID, kind: PasswordKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: id, kind: kind),
        ]
    }
}
