import Foundation
import Security

class AuthManager: ObservableObject {
    @Published var pairingCode: String = ""
    @Published var pairedDevices: [PairedDevice] = []

    private let keychainService = "com.personaldatahub.auth"
    private let tokensKey = "paired_tokens"

    struct PairedDevice: Identifiable, Codable {
        let id: String  // token
        let name: String
        let pairedAt: Date
    }

    init() {
        regeneratePairingCode()
        loadPairedDevices()
    }

    // MARK: - Pairing Code

    func regeneratePairingCode() {
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
    }

    // MARK: - Token Management

    func validatePairingCode(_ code: String, deviceName: String) -> String? {
        guard code == pairingCode else { return nil }

        // Generate a new token
        let token = UUID().uuidString
        let device = PairedDevice(id: token, name: deviceName, pairedAt: Date())

        pairedDevices.append(device)
        savePairedDevices()

        // Generate a new pairing code (old one is consumed)
        regeneratePairingCode()

        return token
    }

    func validateToken(_ token: String) -> Bool {
        return pairedDevices.contains { $0.id == token }
    }

    func revokeDevice(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        savePairedDevices()
    }

    func revokeAll() {
        pairedDevices.removeAll()
        savePairedDevices()
    }

    // MARK: - Auth Middleware

    func authenticateRequest(_ request: Any) -> Bool {
        // Extract token from Swifter's HttpRequest
        // We'll use a protocol-agnostic approach
        return false // Override in Routes
    }

    // MARK: - Keychain Storage

    private func savePairedDevices() {
        guard let data = try? JSONEncoder().encode(pairedDevices) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokensKey,
        ]

        // Delete existing
        SecItemDelete(query as CFDictionary)

        // Add new
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadPairedDevices() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokensKey,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            pairedDevices = []
            return
        }

        pairedDevices = (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }
}
