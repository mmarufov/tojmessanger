import Foundation

/// Wire envelope for the Toj relay. The payload is opaque libsignal ciphertext —
/// the relay routes envelopes and must never be able to read message content.
nonisolated struct Envelope: Codable, Sendable, Equatable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        case msg
        case ack
    }

    var v: Int
    var type: Kind
    var id: String
    var from: String
    var to: String
    /// Raw libsignal `CiphertextMessage.MessageType` (3 = preKey, 2 = whisper).
    var payloadType: UInt8?
    /// Ciphertext bytes; `Codable` renders this as base64 in JSON.
    var payload: Data?
    /// Sender clock, milliseconds since 1970. Informational only — ordering is a later milestone.
    var ts: Int64

    static func message(from: String, to: String, payloadType: UInt8, payload: Data) -> Envelope {
        Envelope(
            v: 1,
            type: .msg,
            id: UUID().uuidString.lowercased(),
            from: from,
            to: to,
            payloadType: payloadType,
            payload: payload,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(from data: Data) -> Envelope? {
        try? JSONDecoder().decode(Envelope.self, from: data)
    }
}
