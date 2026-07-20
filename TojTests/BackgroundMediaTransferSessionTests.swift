import XCTest
@testable import Toj

final class BackgroundMediaTransferSessionTests: XCTestCase {
    func testChunkValidatorAcceptsOnlyContiguousExpectedMediaBytes() throws {
        let mediaId = UUID().uuidString.lowercased()
        let data = Data(repeating: 0x5a, count: 512)
        let result = try BackgroundMediaChunkValidator.validate(
            mediaId: mediaId,
            requestedOffset: 1_024,
            expectedTotalSize: 2_048,
            data: data,
            statusCode: 200,
            nextOffsetHeader: "1536",
            totalSizeHeader: "2048"
        )

        XCTAssertEqual(result.mediaId, mediaId)
        XCTAssertEqual(result.offset, 1_024)
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.nextOffset, 1_536)
        XCTAssertEqual(result.totalSize, 2_048)
    }

    func testChunkValidatorRejectsWrongOffsetSizeAndHTTPFailure() {
        XCTAssertThrowsError(try BackgroundMediaChunkValidator.validate(
            mediaId: UUID().uuidString.lowercased(),
            requestedOffset: 0,
            expectedTotalSize: 2,
            data: Data([0x01]),
            statusCode: 200,
            nextOffsetHeader: "2",
            totalSizeHeader: "2"
        ))
        XCTAssertThrowsError(try BackgroundMediaChunkValidator.validate(
            mediaId: UUID().uuidString.lowercased(),
            requestedOffset: 0,
            expectedTotalSize: 1,
            data: Data([0x01]),
            statusCode: 401,
            nextOffsetHeader: "1",
            totalSizeHeader: "1"
        ))
        XCTAssertThrowsError(try BackgroundMediaChunkValidator.validate(
            mediaId: UUID().uuidString.lowercased(),
            requestedOffset: 0,
            expectedTotalSize: Int64(BackgroundMediaChunkValidator.maximumChunkBytes + 1),
            data: Data(repeating: 0x01, count: BackgroundMediaChunkValidator.maximumChunkBytes + 1),
            statusCode: 200,
            nextOffsetHeader: String(BackgroundMediaChunkValidator.maximumChunkBytes + 1),
            totalSizeHeader: String(BackgroundMediaChunkValidator.maximumChunkBytes + 1)
        ))
    }

    func testDurableJobMetadataNeverContainsCredentials() throws {
        let metadata = BackgroundMediaDownloadJobMetadata(
            mediaId: UUID().uuidString.lowercased(),
            currentOffset: 512,
            expectedTotalSize: 4_096
        )
        let encoded = try JSONEncoder().encode([metadata])
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("token"))
        XCTAssertEqual(
            try JSONDecoder().decode([BackgroundMediaDownloadJobMetadata].self, from: encoded),
            [metadata]
        )
    }

    func testBackgroundConfigurationUsesTheRegisteredMediaSessionIdentifier() {
        let configuration = BackgroundMediaTransferSession.makeConfiguration()

        XCTAssertEqual(configuration.identifier, TojBackgroundTaskIdentifier.mediaSession)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.urlCache)
    }
}
