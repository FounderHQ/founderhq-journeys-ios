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
