import Foundation

public struct JourneyIdentity: Sendable, Equatable {
    public var email: String?
    public var phone: String?
    public var externalID: String?

    public init(email: String? = nil, phone: String? = nil, externalID: String? = nil) {
        self.email = email
        self.phone = phone
        self.externalID = externalID
    }

    var json: JSONValue {
        .object([
            "email": email.map(JSONValue.string) ?? .null,
            "phone": phone.map(JSONValue.string) ?? .null,
            "externalId": externalID.map(JSONValue.string) ?? .null,
        ])
    }
}

public struct JourneyCaptureOptions: Sendable {
    public var context: [String: JSONValue]
    public var captureContext: Bool
    public var redactURLParameters: [String]?
    public var batchSize: Int?
    public var flushIntervalMilliseconds: Int?
    public var maxRetries: Int?
    public var contextProvider: (@Sendable () -> [String: JSONValue])?
    public var transport: (@Sendable (JourneyCaptureTransportRequest) async throws -> Bool)?

    public init(
        context: [String: JSONValue] = [:],
        captureContext: Bool = true,
        redactURLParameters: [String]? = nil,
        batchSize: Int? = nil,
        flushIntervalMilliseconds: Int? = nil,
        maxRetries: Int? = nil,
        contextProvider: (@Sendable () -> [String: JSONValue])? = nil,
        transport: (@Sendable (JourneyCaptureTransportRequest) async throws -> Bool)? = nil
    ) {
        self.context = context
        self.captureContext = captureContext
        self.redactURLParameters = redactURLParameters
        self.batchSize = batchSize
        self.flushIntervalMilliseconds = flushIntervalMilliseconds
        self.maxRetries = maxRetries
        self.contextProvider = contextProvider
        self.transport = transport
    }

    var json: JSONValue {
        var value: [String: JSONValue] = [
            "context": .object(context),
            "captureContext": .bool(captureContext),
        ]
        if let redactURLParameters {
            value["redactUrlParams"] = .array(redactURLParameters.map(JSONValue.string))
        }
        if let batchSize { value["batchSize"] = .number(Double(batchSize)) }
        if let flushIntervalMilliseconds {
            value["flushIntervalMs"] = .number(Double(flushIntervalMilliseconds))
        }
        if let maxRetries { value["maxRetries"] = .number(Double(maxRetries)) }
        return .object(value)
    }
}

public struct JourneyConfiguration: Sendable {
    public static let productionBaseURL = URL(string: "https://app.getfounderhq.com")!

    public var apiKey: String
    public var journeyID: String
    public var baseURL: URL
    public var rendererURL: URL?
    /** Optional local render config. API-key access is still validated before rendering. */
    public var config: JSONValue?
    public var capture: JourneyCaptureOptions?
    public var identity: JourneyIdentity?
    public var initialAnswers: [String: JSONValue]
    public var initialOptions: [String: JSONValue]
    public var storageKey: String?
    public var theme: String?

    public init(
        apiKey: String,
        journeyID: String,
        baseURL: URL = JourneyConfiguration.productionBaseURL,
        rendererURL: URL? = nil,
        config: JSONValue? = nil,
        capture: JourneyCaptureOptions? = JourneyCaptureOptions(),
        identity: JourneyIdentity? = nil,
        initialAnswers: [String: JSONValue] = [:],
        initialOptions: [String: JSONValue] = [:],
        storageKey: String? = nil,
        theme: String? = nil
    ) {
        self.apiKey = apiKey
        self.journeyID = journeyID
        self.baseURL = baseURL
        self.rendererURL = rendererURL
        self.config = config
        self.capture = capture
        self.identity = identity
        self.initialAnswers = initialAnswers
        self.initialOptions = initialOptions
        self.storageKey = storageKey
        self.theme = theme
    }

    public func validatedBaseURL() throws -> URL {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host?.lowercased() else {
            throw JourneyError.invalidURL("baseURL is invalid")
        }
        guard scheme == "https" || (scheme == "http" && Self.isLocalDevelopmentHost(host)) else {
            throw JourneyError.invalidURL(
                "baseURL must use HTTPS (HTTP is supported only for local development)"
            )
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw JourneyError.invalidURL("baseURL is invalid")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else {
            throw JourneyError.invalidURL("baseURL is invalid")
        }
        return origin
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1", "10.0.2.2"].contains(host) {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    public func resolvedRendererURL() throws -> URL {
        if let rendererURL {
            var copy = self
            copy.baseURL = rendererURL
            _ = try copy.validatedBaseURL()
            guard var components = URLComponents(
                url: rendererURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw JourneyError.invalidURL("rendererURL is invalid")
            }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            guard let normalized = components.url else {
                throw JourneyError.invalidURL("rendererURL is invalid")
            }
            return normalized
        }
        return try validatedBaseURL()
            .appendingPathComponent("embed")
            .appendingPathComponent("journeys")
            .appendingPathComponent("native")
    }

    var renderSignature: String {
        let payload: JSONValue = .object([
            "apiKey": .string(apiKey),
            "journeyID": .string(journeyID),
            "baseURL": .string(baseURL.absoluteString),
            "rendererURL": rendererURL.map { .string($0.absoluteString) } ?? .null,
            "config": config ?? .null,
            "capture": capture?.json ?? .bool(false),
            "identity": identity?.json ?? .null,
            "initialAnswers": .object(initialAnswers),
            "initialOptions": .object(initialOptions),
            "storageKey": storageKey.map(JSONValue.string) ?? .null,
            "theme": theme.map(JSONValue.string) ?? .null,
        ])
        return (try? JSONEncoder().encode(payload).base64EncodedString()) ?? journeyID
    }
}

public enum JourneyError: LocalizedError, Equatable {
    case invalidURL(String)
    case unavailable(String)
    case invalidResponse(String)
    case renderer(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(message), let .unavailable(message),
             let .invalidResponse(message), let .renderer(message):
            return message
        }
    }
}
