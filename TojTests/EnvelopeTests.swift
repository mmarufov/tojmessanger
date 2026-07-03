import XCTest
@testable import Toj

final class EnvelopeTests: XCTestCase {
    func testRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0xFF, 0x00, 0x7A])
        let original = Envelope.message(from: "alice", to: "bob", payloadType: 3, payload: payload)

        let encoded = try XCTUnwrap(original.encodedString())
        let decoded = try XCTUnwrap(Envelope.decoded(from: Data(encoded.utf8)))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.type, .msg)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.payloadType, 3)
    }

    func testPayloadIsBase64InJSON() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let envelope = Envelope.message(from: "alice", to: "bob", payloadType: 2, payload: payload)

        let json = try XCTUnwrap(envelope.encodedString())
        XCTAssertTrue(json.contains(payload.base64EncodedString()),
                      "payload must cross the wire as base64, not raw bytes")
    }

    func testDecodingServerAck() throws {
        let json = #"{"v":1,"type":"ack","id":"abc-123","from":"server","to":"alice","ts":1719900000000}"#
        let ack = try XCTUnwrap(Envelope.decoded(from: Data(json.utf8)))
        XCTAssertEqual(ack.type, .ack)
        XCTAssertEqual(ack.id, "abc-123")
        XCTAssertNil(ack.payload)
    }

    func testUnknownTypeFailsDecoding() {
        let json = #"{"v":1,"type":"selfdestruct","id":"x","from":"a","to":"b","ts":0}"#
        XCTAssertNil(Envelope.decoded(from: Data(json.utf8)))
    }
}
