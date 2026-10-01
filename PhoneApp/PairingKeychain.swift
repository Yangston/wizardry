import Foundation
import Security

enum PairingKeychain {
    private static let service = "com.yangston.wizardry.receiver"
    static func save(_ value: String, account: String = "token") throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                 kSecAttrService as String:service,kSecAttrAccount as String:account]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw KeyError.saveFailed }
        } else if update != errSecSuccess { throw KeyError.saveFailed }
    }
    static func load(account: String = "token") -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:account,
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding:data,as:UTF8.self)
    }
    enum KeyError: LocalizedError {
        case saveFailed
        var errorDescription: String? { "Could not securely save pairing. Please unlock your phone and try again." }
    }
}
