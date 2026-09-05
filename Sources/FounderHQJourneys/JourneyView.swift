#if os(iOS)
import SwiftUI
import UIKit
import WebKit

@MainActor
public struct JourneyView: View {
    public typealias DiscountHandler =
        (JourneyDiscountCodeRequest) async throws -> JourneyDiscountCodeResult

    private let configuration: JourneyConfiguration
    private let controller: JourneyController
    private let onEvent: (JourneyEvent) -> Void
    private let onError: (Error) -> Void
    private let onOpenURL: (URL) -> Void
    private let onDiscountCodeApply: DiscountHandler?
    private let onHaptic: ((JourneyHapticType) -> Void)?
    private let loadingView: AnyView?
    private let errorView: ((Error, @escaping () -> Void) -> AnyView)?
    @State private var phase: Phase = .loading
    @State private var reloadID = UUID()

    enum Phase {
        case loading
        case ready
        case failed(Error)
    }

    public init(
        configuration: JourneyConfiguration,
        controller: JourneyController? = nil,
        onEvent: @escaping (JourneyEvent) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in },
        onOpenURL: ((URL) -> Void)? = nil,
        onDiscountCodeApply: DiscountHandler? = nil,
        onHaptic: ((JourneyHapticType) -> Void)? = nil,
        loadingView: AnyView? = nil,
        errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil
    ) {
        self.configuration = configuration
        self.controller = controller ?? JourneyController()
        self.onEvent = onEvent
        self.onError = onError
        self.onOpenURL = onOpenURL ?? { UIApplication.shared.open($0) }
        self.onDiscountCodeApply = onDiscountCodeApply
        self.onHaptic = onHaptic
        self.loadingView = loadingView
        self.errorView = errorView
    }

    public var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 18 / 255, blue: 16 / 255)
                .ignoresSafeArea()
            NativeJourneyWebView(
                configuration: configuration,
                controller: controller,
                phase: $phase,
                onEvent: onEvent,
                onError: onError,
                onOpenURL: onOpenURL,
                onDiscountCodeApply: onDiscountCodeApply,
                onHaptic: onHaptic
            )
            .id(reloadID)
            if case .loading = phase {
                if let loadingView {
                    loadingView
                } else {
                    ProgressView().tint(.white)
                }
            }
            if case let .failed(error) = phase {
                let retry = {
                    phase = .loading
                    reloadID = UUID()
                }
                if let errorView {
                    errorView(error, retry)
                } else {
                    VStack(spacing: 12) {
                        Text("This Journey is unavailable").font(.headline)
                        Text(error.localizedDescription).font(.footnote).opacity(0.7).multilineTextAlignment(.center)
                        Button("Try again", action: retry)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                }
            }
        }
    }
}

private struct NativeJourneyWebView: UIViewRepresentable {
    let configuration: JourneyConfiguration
    let controller: JourneyController
    @Binding var phase: JourneyView.Phase
    let onEvent: (JourneyEvent) -> Void
    let onError: (Error) -> Void
    let onOpenURL: (URL) -> Void
    let onDiscountCodeApply: JourneyView.DiscountHandler?
    let onHaptic: ((JourneyHapticType) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.websiteDataStore = .default()
        webConfiguration.userContentController.add(
            context.coordinator,
            name: JourneyBridge.handlerName
        )
        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 20 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        controller.bind(context.coordinator)
        context.coordinator.start()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        coordinator.parent.controller.unbind(coordinator)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: JourneyBridge.handlerName
        )
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, JourneyCommandSink {
        var parent: NativeJourneyWebView
        weak var webView: WKWebView?
        private let client = JourneyAPIClient()
        private var journeyConfig: JSONValue?
        private var rendererReady = false
        private var queuedCommands: [JSONValue] = []
        private var lifecycleObservers: [NSObjectProtocol] = []
        private var configurationSignature = ""
        private var loadGeneration = 0

        init(parent: NativeJourneyWebView) {
            self.parent = parent
        }

        func attach(_ webView: WKWebView) { self.webView = webView }

        func start() {
            observeLifecycle()
            configurationSignature = parent.configuration.renderSignature
            loadGeneration += 1
            let generation = loadGeneration
            Task {
                do {
                    let config = try await client.fetchConfiguration(for: parent.configuration)
                    guard generation == loadGeneration else { return }
                    journeyConfig = config
                    guard let webView else { return }
                    webView.load(URLRequest(url: try parent.configuration.resolvedRendererURL()))
                } catch {
                    guard generation == loadGeneration else { return }
                    fail(error)
                }
            }
        }

        func update(parent: NativeJourneyWebView) {
            let signature = parent.configuration.renderSignature
            self.parent = parent
            guard signature != configurationSignature else { return }
            rendererReady = false
            journeyConfig = nil
            queuedCommands.removeAll()
            self.parent.phase = .loading
            webView?.stopLoading()
            start()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == JourneyBridge.handlerName,
                  let envelope = JourneyBridge.decode(message.body),
                  let payload = envelope.payload.objectValue else {
                report(JourneyError.renderer("The Journey renderer sent an invalid message"))
                return
            }

            switch envelope.type {
            case "ready":
                rendererReady = true
                initializeRenderer()
            case "event":
                if let rawEvent = payload["event"],
                   let event = JourneyEvent(rawValue: rawEvent) {
                    parent.onEvent(event)
                }
            case "rendered":
                parent.phase = .ready
            case "navigation_state":
                parent.controller.updateNavigation(
                    stepID: payload.string("stepId") ?? "",
                    stepIndex: Int(payload["stepIndex"]?.numberValue ?? 0),
                    canGoBack: payload["canGoBack"]?.boolValue ?? false
                )
            case "haptic":
                if let rawType = payload.string("type"),
                   let type = JourneyHapticType(rawValue: rawType) {
                    if let handler = parent.onHaptic {
                        handler(type)
                    } else {
                        performHaptic(type)
                    }
                }
            case "capture_request":
                handleCapture(payload)
            case "discount_code_request":
                handleDiscount(payload)
            case "open_url":
                if let value = payload.string("url"), let url = URL(string: value) {
                    parent.onOpenURL(url)
                }
            case "error":
                let error = JourneyError.renderer(
                    payload.string("message") ?? "Journey renderer error"
                )
                report(error)
                if payload["recoverable"]?.boolValue == false {
                    parent.phase = .failed(error)
                }
            default:
                break
            }
        }

        func send(command: JSONValue) {
            if rendererReady {
                send(type: "command", payload: command)
            } else {
                queuedCommands.append(command)
            }
        }

        private func initializeRenderer() {
            guard let journeyConfig else { return }
            let configuration = parent.configuration
            var payload: [String: JSONValue] = [
                "journeyId": .string(configuration.journeyID),
                "config": journeyConfig,
                "capture": configuration.capture?.json ?? .bool(false),
                "initialAnswers": .object(configuration.initialAnswers),
                "initialOptions": .object(configuration.initialOptions),
                "platform": .string("ios"),
                "sdkVersion": .string(JourneyBridge.sdkVersion),
            ]
            if let identity = configuration.identity { payload["identity"] = identity.json }
            if let storageKey = configuration.storageKey { payload["storageKey"] = .string(storageKey) }
            if let theme = configuration.theme { payload["theme"] = .string(theme) }
            send(type: "initialize", payload: .object(payload))
            queuedCommands.forEach { send(type: "command", payload: $0) }
            queuedCommands.removeAll()
        }

        private func handleCapture(_ payload: [String: JSONValue]) {
            guard let requestID = payload.string("requestId"),
                  let body = payload["body"] else { return }
            Task {
                do {
                    let status = try await client.capture(body, for: parent.configuration)
                    send(type: "capture_response", payload: .object([
                        "requestId": .string(requestID),
                        "ok": .bool(true),
                        "status": .number(Double(status)),
                    ]))
                } catch {
                    send(type: "capture_response", payload: .object([
                        "requestId": .string(requestID),
                        "ok": .bool(false),
                        "error": .string(error.localizedDescription),
                    ]))
                }
            }
        }

        private func handleDiscount(_ payload: [String: JSONValue]) {
            guard let requestID = payload.string("requestId"),
                  let rawRequest = payload["request"],
                  let request = JourneyDiscountCodeRequest(rawValue: rawRequest) else { return }
            Task {
                do {
                    guard let handler = parent.onDiscountCodeApply else {
                        throw JourneyError.unavailable("No native discount code handler was provided")
                    }
                    let result = try await handler(request)
                    send(type: "discount_code_response", payload: .object([
                        "requestId": .string(requestID),
                        "result": result.rawValue,
                    ]))
                } catch {
                    send(type: "discount_code_response", payload: .object([
                        "requestId": .string(requestID),
                        "error": .string(error.localizedDescription),
                    ]))
                }
            }
        }

        private func send(type: String, payload: JSONValue) {
            do {
                let script = try JourneyBridge.dispatchScript(type: type, payload: payload)
                webView?.evaluateJavaScript(script) { _, error in
                    if let error { self.report(error) }
                }
            } catch {
                report(error)
            }
        }

        private func report(_ error: Error) { parent.onError(error) }

        private func fail(_ error: Error) {
            report(error)
            parent.phase = .failed(error)
        }

        private func observeLifecycle() {
            guard lifecycleObservers.isEmpty else { return }
            let center = NotificationCenter.default
            for name in [UIApplication.didEnterBackgroundNotification,
                         UIApplication.willTerminateNotification] {
                lifecycleObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.send(command: .object(["name": .string("flush_capture")])) }
                    }
                )
            }
        }

        func stop() {
            lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
            lifecycleObservers.removeAll()
        }

        private func performHaptic(_ type: JourneyHapticType) {
            switch type {
            case .selection:
                UISelectionFeedbackGenerator().selectionChanged()
            case .light:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .medium:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .heavy:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .error:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.absoluteString == "about:blank" || isRendererURL(url) {
                decisionHandler(.allow)
            } else {
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    parent.onOpenURL(url)
                }
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            rendererReady = false
            parent.phase = .loading
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            fail(error)
        }

        private func isRendererURL(_ url: URL) -> Bool {
            guard let expected = try? parent.configuration.resolvedRendererURL() else { return false }
            return url.scheme == expected.scheme &&
                url.host == expected.host &&
                url.port == expected.port &&
                url.path == expected.path
        }
    }
}

@MainActor
public final class JourneyViewController: UIViewController {
    private let hostingController: UIHostingController<JourneyView>

    public init(
        configuration: JourneyConfiguration,
        controller: JourneyController? = nil,
        onEvent: @escaping (JourneyEvent) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in },
        onOpenURL: ((URL) -> Void)? = nil,
        onDiscountCodeApply: JourneyView.DiscountHandler? = nil,
        onHaptic: ((JourneyHapticType) -> Void)? = nil,
        loadingView: AnyView? = nil,
        errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil
    ) {
        hostingController = UIHostingController(
            rootView: JourneyView(
                configuration: configuration,
                controller: controller,
                onEvent: onEvent,
                onError: onError,
                onOpenURL: onOpenURL,
                onDiscountCodeApply: onDiscountCodeApply,
                onHaptic: onHaptic,
                loadingView: loadingView,
                errorView: errorView
            )
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }
}
#endif
