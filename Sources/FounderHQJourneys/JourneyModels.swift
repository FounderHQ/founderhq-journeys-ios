import Foundation

public enum JourneyEventType: Equatable, Sendable {
    case sessionStart
    case stepView
    case stepSubmit
    case navigate
    case complete
    case purchaseIntent
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "session_start": self = .sessionStart
        case "step_view": self = .stepView
        case "step_submit": self = .stepSubmit
        case "navigate": self = .navigate
        case "complete": self = .complete
        case "purchase_intent": self = .purchaseIntent
        default: self = .unknown(rawValue)
        }
    }
}

public struct JourneyEvent: Equatable, Sendable {
    public let type: JourneyEventType
    public let rawValue: JSONValue
    public let answers: [String: JSONValue]
    public let computedVariables: [String: JSONValue]

    init?(rawValue: JSONValue) {
        guard let object = rawValue.objectValue,
              let type = object.string("type") else { return nil }
        self.type = JourneyEventType(rawValue: type)
        self.rawValue = rawValue
        answers = object.object("answers") ?? [:]
        computedVariables = object.object("computedVariables") ?? [:]
    }
}

public struct JourneyDiscountCodeRequest: Equatable, Sendable {
    public let rawValue: JSONValue
    public let code: String
    public let variable: String
    public let planVariable: String?
    public let plan: [String: JSONValue]?
    public let answers: [String: JSONValue]

    init?(rawValue: JSONValue) {
        guard let object = rawValue.objectValue,
              let code = object.string("code"),
              let variable = object.string("variable") else { return nil }
        self.rawValue = rawValue
        self.code = code
        self.variable = variable
        planVariable = object.string("planVariable")
        plan = object.object("plan")
        answers = object.object("answers") ?? [:]
    }
}

public struct JourneyDiscountCodeResult: Equatable, Sendable {
    public let rawValue: JSONValue

    public init(valid: Bool, values: [String: JSONValue] = [:]) {
        var object = values
        object["valid"] = .bool(valid)
        rawValue = .object(object)
    }

    public init(rawValue: JSONValue) throws {
        guard rawValue.objectValue != nil else {
            throw JourneyError.invalidResponse("Discount result must be a JSON object")
        }
        self.rawValue = rawValue
    }
}

public enum JourneyHapticType: String, Sendable {
    case selection
    case light
    case medium
    case heavy
    case success
    case warning
    case error
}

public struct JourneyCaptureTransportRequest: Sendable {
    public let url: URL
    public let method: String
    public let body: JSONValue
}

public struct JourneyPreparation: Equatable, Sendable {
    public let config: JSONValue?
    public let revisionID: String
    public let version: Int
    public let captureIdentityMode: String
    public let refreshAfterSeconds: TimeInterval
    public let unchanged: Bool
    var supportsPreparedPresentation = true

    public init(
        config: JSONValue?,
        revisionID: String,
        version: Int,
        captureIdentityMode: String,
        refreshAfterSeconds: TimeInterval,
        unchanged: Bool
    ) {
        self.config = config
        self.revisionID = revisionID
        self.version = version
        self.captureIdentityMode = captureIdentityMode
        self.refreshAfterSeconds = min(1_800, max(600, refreshAfterSeconds))
        self.unchanged = unchanged
    }
}

enum JourneyPreparationDecision: Equatable, Sendable {
    case current
    case refreshRequired
    case unavailable
    case blocked
}

struct JourneyPreparationPolicy: Equatable, Sendable {
    static let maximumStartAge: TimeInterval = 30 * 60

    private(set) var preparation: JourneyPreparation?
    private(set) var queuedPreparation: JourneyPreparation?
    private(set) var lastSuccessAt: Date?
    private(set) var refreshAfterSeconds: TimeInterval = 600
    private(set) var failureCount = 0
    private(set) var authorizationBlocked = false
    private(set) var requestInFlight = false
    private(set) var clientSessionID: String?
    private(set) var retryNotBefore: Date?

    var latestRevisionID: String? {
        queuedPreparation?.revisionID ?? preparation?.revisionID
    }

    func decision(at date: Date) -> JourneyPreparationDecision {
        if authorizationBlocked { return .blocked }
        guard preparation != nil, let lastSuccessAt else { return .unavailable }
        return date.timeIntervalSince(lastSuccessAt) >= refreshAfterSeconds
            ? .refreshRequired : .current
    }

    func needsRefresh(at date: Date) -> Bool {
        decision(at: date) != .current
    }

    func canStart(at date: Date) -> Bool {
        guard !authorizationBlocked, preparation != nil, let lastSuccessAt else { return false }
        return date.timeIntervalSince(lastSuccessAt) <= Self.maximumStartAge
    }

    mutating func recordSuccess(
        _ response: JourneyPreparation,
        at date: Date,
        queueWhilePresented: Bool = false
    ) throws {
        let current = queuedPreparation ?? preparation
        let resolved: JourneyPreparation
        if response.unchanged {
            guard let current, current.revisionID == response.revisionID,
                  let config = current.config else {
                throw JourneyError.invalidResponse("FounderHQ omitted a required Journey configuration")
            }
            resolved = JourneyPreparation(
                config: config,
                revisionID: response.revisionID,
                version: response.version,
                captureIdentityMode: response.captureIdentityMode,
                refreshAfterSeconds: response.refreshAfterSeconds,
                unchanged: true
            )
        } else {
            guard response.config != nil else {
                throw JourneyError.invalidResponse("FounderHQ omitted a required Journey configuration")
            }
            resolved = response
        }
        if queueWhilePresented {
            if queuedPreparation != nil || !response.unchanged {
                queuedPreparation = resolved
            }
        } else {
            preparation = resolved
            queuedPreparation = nil
        }
        lastSuccessAt = date
        refreshAfterSeconds = min(1_800, max(600, response.refreshAfterSeconds))
        failureCount = 0
        authorizationBlocked = false
        retryNotBefore = nil
    }

    mutating func recordFailure(_ error: Error, at date: Date = Date()) {
        failureCount += 1
        if case JourneyError.authorizationDenied = error {
            authorizationBlocked = true
            preparation = nil
            queuedPreparation = nil
            lastSuccessAt = nil
            clientSessionID = nil
            retryNotBefore = nil
        } else if let httpError = error as? JourneyHTTPError,
                  httpError.statusCode == 429,
                  let retryAfter = httpError.retryAfter {
            retryNotBefore = max(retryAfter, date)
        } else {
            let delay = min(300, 30 * pow(2, Double(max(0, failureCount - 1))))
            retryNotBefore = date.addingTimeInterval(delay)
        }
    }

    func canRequest(at date: Date) -> Bool {
        !authorizationBlocked && (retryNotBefore.map { $0 <= date } ?? true)
    }

    mutating func beginManualAuthorizationRetry() {
        authorizationBlocked = false
        failureCount = 0
    }

    func automaticRefreshDate() -> Date? {
        guard failureCount == 0, let lastSuccessAt else { return nil }
        return lastSuccessAt.addingTimeInterval(refreshAfterSeconds)
    }

    @discardableResult
    mutating func activateQueuedPreparation() -> Bool {
        guard let queuedPreparation else { return false }
        preparation = queuedPreparation
        self.queuedPreparation = nil
        return true
    }

    mutating func beginRequest() -> Bool {
        guard !requestInFlight else { return false }
        requestInFlight = true
        return true
    }

    mutating func endRequest() {
        requestInFlight = false
    }

    @discardableResult
    mutating func beginSession(id: String = UUID().uuidString.lowercased()) -> String {
        clientSessionID = id
        return id
    }

    mutating func reset() {
        self = JourneyPreparationPolicy()
    }
}
