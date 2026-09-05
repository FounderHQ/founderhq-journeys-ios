import Foundation

enum JourneyBridge {
    static let version = 1
    static let handlerName = "founderhqJourneysNative"
    static let receiverName = "__founderhqJourneysReceive"
    static let sdkVersion = "0.2.0"

    struct Envelope: Codable, Equatable {
        var version: Int
        var type: String
        var payload: JSONValue
    }

    static func decode(_ value: Any) -> Envelope? {
        let data: Data?
        if let string = value as? String {
            data = string.data(using: .utf8)
        } else if JSONSerialization.isValidJSONObject(value) {
            data = try? JSONSerialization.data(withJSONObject: value)
        } else {
            data = nil
        }
        guard let data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == version else {
            return nil
        }
        return envelope
    }

    static func encode(type: String, payload: JSONValue) throws -> String {
        let envelope = Envelope(version: version, type: type, payload: payload)
        let data = try JSONEncoder().encode(envelope)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JourneyError.invalidResponse("Could not encode bridge message")
        }
        return string
    }

    static func dispatchScript(type: String, payload: JSONValue) throws -> String {
        let message = try encode(type: type, payload: payload)
        let quotedData = try JSONEncoder().encode(message)
        guard let quoted = String(data: quotedData, encoding: .utf8) else {
            throw JourneyError.invalidResponse("Could not encode bridge script")
        }
        return "window.\(receiverName)?.(\(quoted));true;"
    }
}
