import Foundation

public struct JourneyAPIClient: Sendable {
    public init() {}

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
        let body = applyingDynamicContext(body, from: configuration.capture)
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
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw JourneyError.invalidResponse("FounderHQ returned an invalid response")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw JourneyError.unavailable("Capture failed (HTTP \(response.statusCode))")
        }
        return response.statusCode
    }

    private func applyingDynamicContext(
        _ body: JSONValue,
        from options: JourneyCaptureOptions?
    ) -> JSONValue {
        guard let supplied = options?.contextProvider?(),
              !supplied.isEmpty,
              var object = body.objectValue else { return body }
        var context = object["context"]?.objectValue ?? [:]
        supplied.forEach { context[$0.key] = $0.value }
        object["context"] = .object(context)
        return .object(object)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw JourneyError.invalidResponse("FounderHQ returned an invalid response")
        }
        guard (200..<300).contains(response.statusCode) else {
            let serverError = (try? JSONDecoder().decode(JSONValue.self, from: data))?
                .objectValue?["error"]?.stringValue
            throw JourneyError.unavailable(
                serverError ?? "\(fallback) (HTTP \(response.statusCode))"
            )
        }
        return data
    }
}
