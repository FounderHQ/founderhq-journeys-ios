import Foundation

public struct JourneyAPIClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init() {
        send = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw JourneyError.invalidResponse("FounderHQ returned an invalid response")
            }
            return (data, response)
        }
    }

    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    public func prepare(
        for configuration: JourneyConfiguration,
        knownRevisionID: String? = nil
    ) async throws -> JourneyPreparation {
        let endpoint = try endpoint(for: configuration).appendingPathComponent("prepare")
        var request = authorizedRequest(url: endpoint, configuration: configuration)
        request.httpMethod = "POST"
        var body: [String: JSONValue] = [
            "capture": .bool(configuration.capture != nil),
        ]
        if let knownRevisionID { body["knownRevisionId"] = .string(knownRevisionID) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data: Data
        do {
            data = try await response(for: request, fallback: "Journey is unavailable")
        } catch let error as JourneyHTTPError where error.statusCode == 404 {
            return try await legacyPreparation(for: configuration)
        } catch let error as JourneyHTTPError where error.statusCode == 401 || error.statusCode == 403 {
            throw JourneyError.authorizationDenied
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.objectValue,
              let revisionID = object["revisionId"]?.stringValue,
              let version = object["version"]?.numberValue,
              let captureIdentityMode = object["captureIdentityMode"]?.stringValue,
              let refreshAfter = object["refreshAfterSeconds"]?.numberValue,
              let unchanged = object["unchanged"]?.boolValue else {
            throw JourneyError.invalidResponse("FounderHQ returned an invalid preparation")
        }
        let serverConfig = object["config"]
        if unchanged, knownRevisionID == nil || knownRevisionID != revisionID {
            throw JourneyError.invalidResponse(
                "FounderHQ returned an unchanged response for a different revision"
            )
        }
        if !unchanged, serverConfig?.objectValue == nil {
            throw JourneyError.invalidResponse("FounderHQ returned an invalid Journey configuration")
        }
        if let localConfig = configuration.config, localConfig.objectValue == nil {
            throw JourneyError.invalidResponse("Local Journey config must be a JSON object")
        }
        return JourneyPreparation(
            config: configuration.config ?? serverConfig,
            revisionID: revisionID,
            version: Int(version),
            captureIdentityMode: captureIdentityMode,
            refreshAfterSeconds: refreshAfter,
            unchanged: configuration.config == nil ? unchanged : false
        )
    }

    private func legacyPreparation(
        for configuration: JourneyConfiguration
    ) async throws -> JourneyPreparation {
        do {
            let config = try await fetchConfiguration(for: configuration)
            var result = JourneyPreparation(
                config: config,
                revisionID: "legacy",
                version: 0,
                captureIdentityMode: configuration.identity == nil ? "anonymous" : "identified",
                refreshAfterSeconds: 600,
                unchanged: false
            )
            result.supportsPreparedPresentation = false
            return result
        } catch let error as JourneyHTTPError where error.isDefinitiveAuthorizationDenial {
            throw JourneyError.authorizationDenied
        }
    }

    public func fetchConfiguration(for configuration: JourneyConfiguration) async throws -> JSONValue {
        let endpoint = try endpoint(for: configuration)
        var validationRequest = authorizedRequest(
            url: endpoint.appendingPathComponent("validate"),
            configuration: configuration
        )
        validationRequest.httpMethod = "POST"
        validationRequest.httpBody = try JSONSerialization.data(
            withJSONObject: ["capture": configuration.capture != nil]
        )
        _ = try await response(for: validationRequest, fallback: "Journey is unavailable")

        if let config = configuration.config {
            guard config.objectValue != nil else {
                throw JourneyError.invalidResponse("Local Journey config must be a JSON object")
            }
            return config
        }

        let request = authorizedRequest(url: endpoint, configuration: configuration)
        let data = try await response(for: request, fallback: "Failed to fetch Journey")
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let config = root.objectValue?["config"], config.objectValue != nil else {
            throw JourneyError.invalidResponse(
                "FounderHQ returned an invalid Journey configuration"
            )
        }
        return config
    }

    public func capture(
        _ body: JSONValue,
        for configuration: JourneyConfiguration
    ) async throws -> Int {
        let url = try endpoint(for: configuration).appendingPathComponent("capture")
        if let transport = configuration.capture?.transport {
            let delivered = try await transport(
                JourneyCaptureTransportRequest(url: url, method: "POST", body: body)
            )
            guard delivered else {
                throw JourneyError.unavailable("Capture transport rejected the batch")
            }
            return 200
        }
        var request = authorizedRequest(url: url, configuration: configuration)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpError(data: data, response: response, fallback: "Capture failed")
        }
        return response.statusCode
    }

    func endpoint(for configuration: JourneyConfiguration) throws -> URL {
        try configuration.validatedBaseURL()
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("journeys")
            .appendingPathComponent(configuration.journeyID)
    }

    private func authorizedRequest(
        url: URL,
        configuration: JourneyConfiguration
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func response(for request: URLRequest, fallback: String) async throws -> Data {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpError(data: data, response: response, fallback: fallback)
        }
        return data
    }

    static func httpError(
        data: Data,
        response: HTTPURLResponse,
        fallback: String,
        now: Date = Date()
    ) -> JourneyHTTPError {
        let serverError = (try? JSONDecoder().decode(JSONValue.self, from: data))?
            .objectValue?["error"]?.stringValue
        return JourneyHTTPError(
            statusCode: response.statusCode,
            retryAfter: retryAfterDate(response.value(forHTTPHeaderField: "Retry-After"), now: now),
            message: serverError ?? "\(fallback) (HTTP \(response.statusCode))"
        )
    }

    static func retryAfterDate(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return now.addingTimeInterval(max(0, seconds))
        }
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
