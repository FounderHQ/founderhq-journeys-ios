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

    func testProductionAPIAndRendererUseAppHost() throws {
        var configuration = JourneyConfiguration(apiKey: "fhq_pk_test", journeyID: "journey")
        XCTAssertEqual(try configuration.validatedBaseURL().absoluteString, "https://app.getfounderhq.com")
        XCTAssertEqual(try configuration.resolvedRendererURL().absoluteString, "https://app.getfounderhq.com/embed/journeys/native")
        configuration.baseURL = URL(string: "http://10.0.2.2:3000")!
        XCTAssertEqual(try configuration.resolvedRendererURL().absoluteString, "http://10.0.2.2:3000/embed/journeys/native")
        configuration.rendererURL = URL(string: "https://renderer.example.com/custom")!
        XCTAssertEqual(try configuration.resolvedRendererURL().absoluteString, "https://renderer.example.com/custom")
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

    func testPreparationRequestAndResponse() async throws {
        final class RequestBox: @unchecked Sendable { var request: URLRequest? }
        let box = RequestBox()
        let client = JourneyAPIClient { request in
            box.request = request
            let data = try JSONEncoder().encode(JSONValue.object([
                "config": .object(["title": .string("Prepared")]),
                "revisionId": .string("revision-2"),
                "version": .number(2),
                "captureIdentityMode": .string("identified"),
                "refreshAfterSeconds": .number(120),
                "unchanged": .bool(false),
            ]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let configuration = JourneyConfiguration(
            apiKey: "fhq_pk_test", journeyID: "journey-1",
            baseURL: URL(string: "https://example.com")!
        )
        let prepared = try await client.prepare(
            for: configuration, knownRevisionID: "revision-1"
        )

        XCTAssertEqual(box.request?.httpMethod, "POST")
        XCTAssertEqual(box.request?.url?.path, "/api/v1/journeys/journey-1/prepare")
        let requestBody = try JSONDecoder().decode(JSONValue.self, from: box.request!.httpBody!)
        XCTAssertEqual(requestBody.objectValue?["capture"], .bool(true))
        XCTAssertEqual(requestBody.objectValue?["knownRevisionId"], .string("revision-1"))
        XCTAssertEqual(prepared.revisionID, "revision-2")
        XCTAssertEqual(prepared.refreshAfterSeconds, 600)
    }

    func testPreparationRejectsAuthorizationDenial() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object(["error": .string("denied")]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil
            )!)
        }
        do {
            _ = try await client.prepare(for: JourneyConfiguration(
                apiKey: "fhq_pk_test", journeyID: "journey"
            ))
            XCTFail("Expected authorization denial")
        } catch {
            XCTAssertEqual(error as? JourneyError, .authorizationDenied)
        }
    }

    func testMissingPrepareEndpointFallsBackToValidatedLegacyConfiguration() async throws {
        final class Paths: @unchecked Sendable { var values: [String] = [] }
        let paths = Paths()
        let client = JourneyAPIClient { request in
            paths.values.append(request.url!.path)
            let path = request.url!.path
            let status: Int
            let value: JSONValue
            if path.hasSuffix("/prepare") {
                status = 404
                value = .object(["error": .string("Route not found")])
            } else if path.hasSuffix("/validate") {
                status = 200
                value = .object(["valid": .bool(true)])
            } else {
                status = 200
                value = .object(["config": .object(["title": .string("Legacy")])])
            }
            return (try JSONEncoder().encode(value), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!)
        }

        let prepared = try await client.prepare(for: JourneyConfiguration(
            apiKey: "fhq_pk_test", journeyID: "journey"
        ))

        XCTAssertEqual(paths.values, [
            "/api/v1/journeys/journey/prepare",
            "/api/v1/journeys/journey/validate",
            "/api/v1/journeys/journey",
        ])
        XCTAssertEqual(prepared.config, .object(["title": .string("Legacy")]))
        XCTAssertFalse(prepared.supportsPreparedPresentation)
    }

    func testPrepare404ConfirmedByValidationBecomesDefinitiveDenial() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object(["error": .string("Not found")]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!)
        }

        do {
            _ = try await client.prepare(for: JourneyConfiguration(
                apiKey: "fhq_pk_test", journeyID: "missing"
            ))
            XCTFail("Expected a definitive denial")
        } catch {
            XCTAssertEqual(error as? JourneyError, .authorizationDenied)
        }
    }

    func testHTTPErrorParsesRetryAfterSecondsAndDate() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let secondsResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "90"]
        )!
        let secondsError = JourneyAPIClient.httpError(
            data: Data(), response: secondsResponse, fallback: "Rate limited", now: now
        )
        XCTAssertEqual(secondsError.statusCode, 429)
        XCTAssertEqual(secondsError.retryAfter, now.addingTimeInterval(90))

        let expected = now.addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let dateResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": formatter.string(from: expected)]
        )!
        XCTAssertEqual(
            JourneyAPIClient.httpError(
                data: Data(), response: dateResponse, fallback: "Rate limited", now: now
            ).retryAfter,
            expected
        )
    }

    func testCapturePreservesDefinitiveHTTPStatusMetadata() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object(["error": .string("Not found")]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!)
        }
        do {
            _ = try await client.capture(.object(["events": .array([])]), for: JourneyConfiguration(
                apiKey: "fhq_pk_test", journeyID: "missing"
            ))
            XCTFail("Expected HTTP failure")
        } catch let error as JourneyHTTPError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertTrue(error.isDefinitiveAuthorizationDenial)
        }
    }

    func testCaptureRateLimitReportsRemainingRetryMilliseconds() {
        let now = Date(timeIntervalSince1970: 10_000)
        let error = JourneyHTTPError(
            statusCode: 429,
            retryAfter: now.addingTimeInterval(12),
            message: "Rate limited"
        )

        XCTAssertEqual(error.retryAfterMilliseconds(at: now), 12_000)
        XCTAssertEqual(error.retryAfterMilliseconds(at: now.addingTimeInterval(20)), 0)
        XCTAssertNil(JourneyHTTPError(
            statusCode: 503,
            retryAfter: now.addingTimeInterval(10),
            message: "Unavailable"
        ).retryAfterMilliseconds(at: now))
    }

    func testUnchangedPreparationMayOmitConfigAndUsesMaximumRefreshClamp() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object([
                "revisionId": .string("revision-1"),
                "version": .number(1),
                "captureIdentityMode": .string("anonymous"),
                "refreshAfterSeconds": .number(9_000),
                "unchanged": .bool(true),
            ]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let response = try await client.prepare(for: JourneyConfiguration(
            apiKey: "fhq_pk_test", journeyID: "journey"
        ), knownRevisionID: "revision-1")
        XCTAssertTrue(response.unchanged)
        XCTAssertNil(response.config)
        XCTAssertEqual(response.refreshAfterSeconds, 1_800)
    }

    func testClientRejectsUnchangedResponseForDifferentRequestedRevision() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object([
                "revisionId": .string("revision-2"),
                "version": .number(2),
                "captureIdentityMode": .string("anonymous"),
                "refreshAfterSeconds": .number(600),
                "unchanged": .bool(true),
            ]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        do {
            _ = try await client.prepare(for: JourneyConfiguration(
                apiKey: "fhq_pk_test", journeyID: "journey"
            ), knownRevisionID: "revision-1")
            XCTFail("Expected mismatched unchanged response to fail")
        } catch {
            XCTAssertEqual(
                error as? JourneyError,
                .invalidResponse("FounderHQ returned an unchanged response for a different revision")
            )
        }
    }

    func testPreparePreservesValidatedLocalTestConfiguration() async throws {
        let client = JourneyAPIClient { request in
            let data = try JSONEncoder().encode(JSONValue.object([
                "revisionId": .string("published-revision"),
                "version": .number(3),
                "captureIdentityMode": .string("anonymous"),
                "refreshAfterSeconds": .number(600),
                "unchanged": .bool(true),
            ]))
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let local = JSONValue.object(["title": .string("Local preview")])
        let prepared = try await client.prepare(for: JourneyConfiguration(
            apiKey: "fhq_pk_test", journeyID: "journey", config: local
        ), knownRevisionID: "published-revision")

        XCTAssertEqual(prepared.config, local)
        XCTAssertFalse(prepared.unchanged)
    }

    func testPreparationPolicyHonorsRefreshAndMaximumStartBoundaries() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(refreshAfter: 1), at: clock.now)

        XCTAssertEqual(policy.decision(at: clock.advanced(by: 599)), .current)
        XCTAssertEqual(policy.decision(at: clock.advanced(by: 600)), .refreshRequired)
        XCTAssertTrue(policy.canStart(at: clock.advanced(by: 1_800)))
        XCTAssertFalse(policy.canStart(at: clock.advanced(by: 1_800.001)))
    }

    func testFailedRefreshDoesNotRenewFreshnessAndRemainsRetryable() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 2_000))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(), at: clock.now)
        policy.recordFailure(
            JourneyError.unavailable("offline"),
            at: clock.advanced(by: 600)
        )

        XCTAssertEqual(policy.lastSuccessAt, clock.now)
        XCTAssertEqual(policy.decision(at: clock.advanced(by: 600)), .refreshRequired)
        XCTAssertEqual(policy.failureCount, 1)
        XCTAssertTrue(policy.canStart(at: clock.advanced(by: 1_800)))
        XCTAssertFalse(policy.canStart(at: clock.advanced(by: 1_800.001)))
        XCTAssertNil(policy.automaticRefreshDate())
        XCTAssertFalse(policy.canRequest(at: clock.advanced(by: 629)))
        XCTAssertTrue(policy.canRequest(at: clock.advanced(by: 630)))
    }

    func testActiveRefreshQueuesNextRevisionWithoutChangingCurrentContent() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 2_500))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(revision: "visible-revision"), at: clock.now)

        try policy.recordSuccess(
            preparation(
                revision: "next-revision",
                config: .object(["title": .string("Next")])
            ),
            at: clock.advanced(by: 600),
            queueWhilePresented: true
        )

        XCTAssertEqual(policy.preparation?.revisionID, "visible-revision")
        XCTAssertEqual(policy.queuedPreparation?.revisionID, "next-revision")
        XCTAssertEqual(policy.latestRevisionID, "next-revision")
        XCTAssertTrue(policy.activateQueuedPreparation())
        XCTAssertEqual(policy.preparation?.revisionID, "next-revision")
        XCTAssertNil(policy.queuedPreparation)
    }

    func testSuccessSchedulesOneFreshnessRefreshButFailureSchedulesNone() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 2_750))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(refreshAfter: 900), at: clock.now)
        XCTAssertEqual(policy.automaticRefreshDate(), clock.advanced(by: 900))

        policy.recordFailure(
            JourneyError.unavailable("offline"),
            at: clock.advanced(by: 900)
        )
        XCTAssertNil(policy.automaticRefreshDate())
    }

    func testUnchangedSuccessRetainsConfigAndRenewsFreshness() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 3_000))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(revision: "revision-1"), at: clock.now)
        let refreshedAt = clock.advanced(by: 600)
        try policy.recordSuccess(
            preparation(revision: "revision-1", refreshAfter: 900, unchanged: true, config: nil),
            at: refreshedAt
        )

        XCTAssertEqual(policy.preparation?.config, .object(["title": .string("Prepared")]))
        XCTAssertEqual(policy.lastSuccessAt, refreshedAt)
        XCTAssertEqual(policy.decision(at: refreshedAt.addingTimeInterval(899)), .current)
        XCTAssertEqual(policy.decision(at: refreshedAt.addingTimeInterval(900)), .refreshRequired)
    }

    func testMismatchedUnchangedRevisionDoesNotRenewFreshness() throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 3_500))
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(revision: "revision-1"), at: clock.now)

        XCTAssertThrowsError(try policy.recordSuccess(
            preparation(revision: "revision-2", unchanged: true, config: nil),
            at: clock.advanced(by: 600)
        ))
        XCTAssertEqual(policy.preparation?.revisionID, "revision-1")
        XCTAssertEqual(policy.lastSuccessAt, clock.now)
        XCTAssertEqual(policy.decision(at: clock.advanced(by: 600)), .refreshRequired)
    }

    func testPreparationPolicyCoalescesRequests() {
        var policy = JourneyPreparationPolicy()
        XCTAssertTrue(policy.beginRequest())
        XCTAssertFalse(policy.beginRequest())
        policy.endRequest()
        XCTAssertTrue(policy.beginRequest())
    }

    func testAuthorizationDenialPurgesPreparedContentAndBlocksRetry() throws {
        let now = Date(timeIntervalSince1970: 4_000)
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(), at: now)
        policy.beginSession(id: "session-one")
        policy.recordFailure(JourneyError.authorizationDenied)

        XCTAssertEqual(policy.decision(at: now), .blocked)
        XCTAssertNil(policy.preparation)
        XCTAssertNil(policy.lastSuccessAt)
        XCTAssertNil(policy.clientSessionID)
        XCTAssertFalse(policy.canStart(at: now))
        XCTAssertFalse(policy.canRequest(at: now))
        XCTAssertNil(policy.automaticRefreshDate())
    }

    func testDefinitiveDenialClassifierCoversPrepareAndCaptureErrors() {
        XCTAssertTrue(isDefinitiveJourneyAuthorizationDenial(JourneyError.authorizationDenied))
        for status in [401, 403, 404] {
            XCTAssertTrue(isDefinitiveJourneyAuthorizationDenial(JourneyHTTPError(
                statusCode: status, message: "Denied"
            )))
        }
        XCTAssertFalse(isDefinitiveJourneyAuthorizationDenial(JourneyHTTPError(
            statusCode: 429, message: "Rate limited"
        )))
        XCTAssertFalse(isDefinitiveJourneyAuthorizationDenial(JourneyError.unavailable("Offline")))
    }

    func testManualRetryCanRecoverAfterDefinitiveDenialWithoutCachedContent() throws {
        let now = Date(timeIntervalSince1970: 4_500)
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(revision: "old-revision"), at: now)
        policy.recordFailure(JourneyError.authorizationDenied, at: now.addingTimeInterval(600))

        XCTAssertTrue(policy.authorizationBlocked)
        XCTAssertNil(policy.preparation)
        XCTAssertFalse(policy.canRequest(at: now.addingTimeInterval(601)))

        policy.beginManualAuthorizationRetry()
        XCTAssertTrue(policy.canRequest(at: now.addingTimeInterval(601)))
        try policy.recordSuccess(
            preparation(revision: "restored-revision"),
            at: now.addingTimeInterval(601)
        )
        XCTAssertEqual(policy.preparation?.revisionID, "restored-revision")
        XCTAssertTrue(policy.canStart(at: now.addingTimeInterval(601)))
    }

    func testEveryPreparationCycleUsesANewSession() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        var policy = JourneyPreparationPolicy()
        try policy.recordSuccess(preparation(), at: now)

        XCTAssertEqual(policy.beginSession(id: "first-presentation"), "first-presentation")
        XCTAssertEqual(policy.beginSession(id: "next-prepared-presentation"), "next-prepared-presentation")
        XCTAssertEqual(policy.clientSessionID, "next-prepared-presentation")
    }

    func testCustomCaptureTransportReceivesRendererBodyUnchanged() async throws {
        actor BodyBox {
            var body: JSONValue?
            func set(_ body: JSONValue) { self.body = body }
        }
        let box = BodyBox()
        let original = JSONValue.object([
            "events": .array([.object(["type": .string("step_view")])]),
            "context": .object(["source": .string("renderer")]),
        ])
        let configuration = JourneyConfiguration(
            apiKey: "fhq_pk_test",
            journeyID: "journey",
            capture: JourneyCaptureOptions(
                contextProvider: { ["hostOnly": .bool(true)] },
                transport: { request in await box.set(request.body); return true }
            )
        )
        _ = try await JourneyAPIClient().capture(original, for: configuration)
        let deliveredBody = await box.body
        XCTAssertEqual(deliveredBody, original)
    }

    private func preparation(
        revision: String = "revision-1",
        refreshAfter: TimeInterval = 600,
        unchanged: Bool = false,
        config: JSONValue? = .object(["title": .string("Prepared")])
    ) -> JourneyPreparation {
        JourneyPreparation(
            config: config,
            revisionID: revision,
            version: 1,
            captureIdentityMode: "anonymous",
            refreshAfterSeconds: refreshAfter,
            unchanged: unchanged
        )
    }
}

private struct FakeClock {
    let now: Date

    func advanced(by seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }
}
