import Foundation

#if os(iOS)
import SwiftUI

@MainActor
protocol JourneyCommandSink: AnyObject {
    func send(command: JSONValue)
}

@MainActor
public final class JourneyController: ObservableObject {
    @Published public private(set) var canGoBack = false
    @Published public private(set) var currentStepID: String?
    @Published public private(set) var currentStepIndex = 0
    weak var sink: JourneyCommandSink?
    private var queuedCommands: [JSONValue] = []

    public init() {}

    func bind(_ sink: JourneyCommandSink) {
        self.sink = sink
        queuedCommands.forEach { sink.send(command: $0) }
        queuedCommands.removeAll()
    }

    func unbind(_ sink: JourneyCommandSink) {
        if self.sink === sink { self.sink = nil }
    }

    private func send(_ value: [String: JSONValue]) {
        let command = JSONValue.object(value)
        if let sink { sink.send(command: command) }
        else { queuedCommands.append(command) }
    }

    public func goNext(answer: JSONValue? = nil) {
        var command: [String: JSONValue] = ["name": .string("go_next")]
        if let answer { command["answer"] = answer }
        send(command)
    }

    public func goBack() { send(["name": .string("go_back")]) }

    public func goToStep(_ stepID: String) {
        send(["name": .string("go_to_step"), "stepId": .string(stepID)])
    }

    public func setAnswer(_ answer: JSONValue, for variable: String) {
        send([
            "name": .string("set_answer"),
            "variable": .string(variable),
            "answer": answer,
        ])
    }

    public func flushCapture() { send(["name": .string("flush_capture")]) }
    public func reload() { send(["name": .string("reload")]) }

    func updateNavigation(stepID: String, stepIndex: Int, canGoBack: Bool) {
        currentStepID = stepID
        currentStepIndex = stepIndex
        self.canGoBack = canGoBack
    }
}
#endif
