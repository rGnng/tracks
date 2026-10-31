import XCTest
@testable import Audia

final class UUIDURLTests: XCTestCase {
    func testKnownUUIDEncodesAndDecodes() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        let encoded = UUIDURL.base64URL(for: uuid)

        XCTAssertEqual(encoded, "VQ6EAOKbQdSnFkRmVUQAAA")
        XCTAssertEqual(encoded.count, 22)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(UUIDURL.uuid(fromBase64URL: encoded), uuid)
    }

    func testURLSafeAlphabetEncodesAndDecodes() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "c3e2b66e-79c1-40b9-7cce-fbc88961c82a"))
        let encoded = UUIDURL.base64URL(for: uuid)

        XCTAssertEqual(encoded, "w-K2bnnBQLl8zvvIiWHIKg")
        XCTAssertEqual(UUIDURL.uuid(fromBase64URL: encoded), uuid)
    }

    func testCopyValueTrimsPrefixAndConcatenatesDirectly() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))

        XCTAssertEqual(
            UUIDURL.copyValue(prefix: "  https://tracks.example/song/  ",
                              uuid: uuid,
                              style: .uuid),
            "https://tracks.example/song/550E8400-E29B-41D4-A716-446655440000"
        )
        XCTAssertEqual(
            UUIDURL.copyValue(prefix: "tracks://",
                              uuid: uuid,
                              style: .base64URL),
            "tracks://VQ6EAOKbQdSnFkRmVUQAAA"
        )
        XCTAssertEqual(
            UUIDURL.copyValue(prefix: "   ",
                              uuid: uuid,
                              style: .base64URL),
            "VQ6EAOKbQdSnFkRmVUQAAA"
        )
    }
}
