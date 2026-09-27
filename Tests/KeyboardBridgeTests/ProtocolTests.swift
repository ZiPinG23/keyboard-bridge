import Foundation
import CryptoKit
@main struct ProtocolTests {
    static func main() throws { try testAuthenticatedRoundTripAndTampering(); testPhysicalGamingKeys(); print("PASS: authenticated roundtrip, tamper/wrong-key rejection, physical key mapping") }
    static func testAuthenticatedRoundTripAndTampering() throws {
        let state = KeyboardState(version: 1, session: "test-session", sequence: 42, enabled: true, modifiers: 2, keys: [4,26,44])
        let secret = "unit-test-key-12345"
        let envelope = try JSONDecoder().decode(Envelope.self, from: encodeState(state, secret: secret))
        let payload = Data(base64Encoded: envelope.payload)!
        let mac = Data(base64Encoded: envelope.mac)!
        let key = SymmetricKey(data: Data(secret.utf8))
        assert(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: key))
        let decoded = try JSONDecoder().decode(KeyboardState.self, from: payload)
        assert(decoded == state)
        assert(!HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload + Data([0]), using: key))
        assert(!HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: SymmetricKey(data: Data("wrong key".utf8))))
    }
    static func testPhysicalGamingKeys() {
        assert(hidKeys[13] == 0x1a) // W
        assert(hidKeys[0] == 0x04) // A
        assert(hidKeys[1] == 0x16) // S
        assert(hidKeys[2] == 0x07) // D
        assert(hidKeys[49] == 0x2c) // Space
        assert(hidKeys[63] == nil) // Fn has no ordinary keyboard usage
    }
}
