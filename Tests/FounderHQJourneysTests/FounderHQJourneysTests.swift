import XCTest
@testable import FounderHQJourneys

final class FounderHQJourneysTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("FounderHQ"),
            "enabled": .bool(true),
            "items": .array([.number(1), .null]),
        ])
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), value)
    }

    func testBridgeRejectsIncompatibleVersion() throws {
        let data = try JSONEncoder().encode(
            JourneyBridge.Envelope(version: 2, type: "ready", payload: .object([:]))
        )
        XCTAssertNil(JourneyBridge.decode(String(decoding: data, as: UTF8.self)))
    }

    func testBaseURLSecurity() throws {
        let secure = JourneyConfiguration(
            apiKey: "fhq_pk_test",
            journeyID: "journey",
            baseURL: URL(string: "https://example.com/path")!
        )
        XCTAssertEqual(try secure.validatedBaseURL().absoluteString, "https://example.com")

        let privateLAN = JourneyConfiguration(
            apiKey: "fhq_pk_test",
            journeyID: "journey",
            baseURL: URL(string: "http://10.10.20.11:3002/path")!
        )
        XCTAssertEqual(
            try privateLAN.validatedBaseURL().absoluteString,
            "http://10.10.20.11:3002"
        )

        let insecure = JourneyConfiguration(
            apiKey: "fhq_pk_test",
            journeyID: "journey",
            baseURL: URL(string: "http://example.com")!
        )
        XCTAssertThrowsError(try insecure.validatedBaseURL())

        let outsidePrivateLAN = JourneyConfiguration(
            apiKey: "fhq_pk_test",
            journeyID: "journey",
            baseURL: URL(string: "http://172.32.0.5")!
        )
        XCTAssertThrowsError(try outsidePrivateLAN.validatedBaseURL())
    }

    func testTypedJourneyEventAndDiscountModels() throws {
        let event = JourneyEvent(rawValue: .object([
            "type": .string("complete"),
            "answers": .object(["plan": .string("pro")]),
            "computedVariables": .object(["score": .number(10)]),
        ]))
        XCTAssertEqual(event?.type, .complete)
        XCTAssertEqual(event?.answers["plan"], .string("pro"))

        let request = JourneyDiscountCodeRequest(rawValue: .object([
            "code": .string("SAVE20"),
            "variable": .string("discount"),
            "answers": .object([:]),
        ]))
        XCTAssertEqual(request?.code, "SAVE20")
        XCTAssertEqual(
            JourneyDiscountCodeResult(valid: false, values: ["reason": .string("Expired")])
                .rawValue.objectValue?["valid"],
            .bool(false)
        )
    }
}
