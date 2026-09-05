#if os(iOS)
import SwiftUI
import UIKit
import WebKit

public enum JourneyReadiness: Equatable, Sendable {
    case idle, preparing, ready, directPresentation, failed, disposed
}

@MainActor
private final class JourneyPresentationDeadline {
    private var continuation: CheckedContinuation<Void, Error>?
    var operationTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

private final class JourneyWeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
public final class JourneyHost: NSObject, ObservableObject {
    public typealias DiscountHandler = (JourneyDiscountCodeRequest) async throws -> JourneyDiscountCodeResult

    @Published public private(set) var readiness: JourneyReadiness = .idle
    @Published public private(set) var isPresented = false
    @Published public private(set) var retryAvailableAt: Date?
    @Published public private(set) var lastError: Error?
    public private(set) var configuration: JourneyConfiguration
    public let controller: JourneyController
    public let webView: WKWebView
    private let messageHandler = JourneyWeakMessageHandler()
    private var preparationContainer: UIView?

    private let client: JourneyAPIClient
    private let onEvent: (JourneyEvent) -> Void
    private let onError: (Error) -> Void
    private let onOpenURL: (URL) -> Void
    private let onDiscountCodeApply: DiscountHandler?
    private let onHaptic: ((JourneyHapticType) -> Void)?
    private var policy = JourneyPreparationPolicy()
    private var rendererReady = false
    private var rendererCapabilities = Set<String>()
    private var rendererInitialized = false
    private var rendererConfiguration: JourneyConfiguration?
    private var queuedCommands: [JSONValue] = []
    private var shellWaiters: [CheckedContinuation<Void, Error>] = []
    private var renderWaiters: [CheckedContinuation<Void, Error>] = []
    private var preparationTask: Task<Void, Error>?
    private var preparationTaskID: UUID?
    private var hiddenPreparationTask: Task<Void, Error>?
    private var hiddenPreparationTaskID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var retryUnlockTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var configurationSignature: String
    private var configurationGeneration = 0
    private var retryError: Error?

    public var canRetry: Bool {
        retryAvailableAt.map { $0 <= Date() } ?? true
    }

    public init(
        configuration: JourneyConfiguration,
        controller: JourneyController? = nil,
        onEvent: @escaping (JourneyEvent) -> Void = { _ in },
        onError: @escaping (Error) -> Void = { _ in },
        onOpenURL: ((URL) -> Void)? = nil,
        onDiscountCodeApply: DiscountHandler? = nil,
        onHaptic: ((JourneyHapticType) -> Void)? = nil
    ) {
        self.configuration = configuration
        configurationSignature = configuration.renderSignature
        self.controller = controller ?? JourneyController()
        client = JourneyAPIClient()
        self.onEvent = onEvent
        self.onError = onError
        self.onOpenURL = onOpenURL ?? { UIApplication.shared.open($0) }
        self.onDiscountCodeApply = onDiscountCodeApply
        self.onHaptic = onHaptic
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init()
        messageHandler.delegate = self
        webView.configuration.userContentController.add(messageHandler, name: JourneyBridge.handlerName)
        webView.isOpaque = false
        webView.isHidden = true
        webView.backgroundColor = UIColor(red: 20 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        self.controller.bind(self)
        observeLifecycle()
    }

    deinit {
        refreshTask?.cancel()
        preparationTask?.cancel()
        hiddenPreparationTask?.cancel()
        retryUnlockTask?.cancel()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let preparationContainer {
            Task { @MainActor in preparationContainer.removeFromSuperview() }
        }
    }

    public func prepare() async throws {
        try await prepare(allowAuthorizationRetry: true)
    }

    private func prepare(allowAuthorizationRetry: Bool) async throws {
        guard readiness != .disposed else { throw JourneyError.unavailable("Journey host was disposed") }
        if policy.authorizationBlocked {
            guard allowAuthorizationRetry else { throw JourneyError.authorizationDenied }
            policy.beginManualAuthorizationRetry()
            lastError = nil
        }
        if let hiddenPreparationTask { try await hiddenPreparationTask.value }
        let now = Date()
        if !policy.canRequest(at: now) {
            throw retryError ?? JourneyError.unavailable("Journey is temporarily unavailable")
        }
        if policy.canStart(at: now), !policy.needsRefresh(at: now),
           isPresented || readiness == .ready || readiness == .directPresentation { return }
        if let preparationTask { return try await preparationTask.value }
        guard policy.beginRequest() else { return }
        let restoreCachedRenderer = policy.canStart(at: now) && !policy.needsRefresh(at: now) &&
            policy.preparation != nil
        let taskID = UUID()
        let generation = configurationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if restoreCachedRenderer {
                try await self.restoreCachedRenderer(generation: generation)
            } else {
                try await self.performPreparation(generation: generation)
            }
        }
        preparationTask = task
        preparationTaskID = taskID
        defer {
            if preparationTaskID == taskID {
                preparationTask = nil
                preparationTaskID = nil
                policy.endRequest()
            }
        }
        try await task.value
    }

    public func present() async throws {
        guard readiness != .disposed else { throw JourneyError.unavailable("Journey host was disposed") }
        guard !policy.authorizationBlocked else { throw JourneyError.authorizationDenied }
        if isPresented { return }
        do {
            let now = Date()
            let canRevealCached = policy.canStart(at: now) &&
                (readiness == .ready || readiness == .directPresentation)
            try await withTimeout(seconds: 15) { [weak self] in
                guard let self else { return }
                if !canRevealCached { try await self.prepare() }
                try await self.revealPreparedRenderer()
            }
            removePreparationViewport()
            webView.isHidden = false
            isPresented = true
            lastError = nil
            refreshTask?.cancel()
            if policy.needsRefresh(at: now) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.prepare(allowAuthorizationRetry: false) } catch { self.onError(error) }
                }
            } else {
                scheduleRefreshIfNeeded()
            }
        } catch {
            if error as? JourneyError == .unavailable("Journey presentation timed out") {
                preparationTask?.cancel()
                hiddenPreparationTask?.cancel()
                rendererReady = false
                rendererInitialized = false
                webView.stopLoading()
                resumeShellWaiters(throwing: error)
                resumeRenderWaiters(throwing: error)
            }
            readiness = .failed
            lastError = error
            onError(error)
            throw error
        }
    }

    private func restoreCachedRenderer(generation: Int) async throws {
        do {
            readiness = .preparing
            try await ensureRendererLoaded()
            guard generation == configurationGeneration else { throw CancellationError() }
            policy.beginSession()
            if policy.preparation?.supportsPreparedPresentation == true,
               rendererCapabilities.contains("prepare"), rendererCapabilities.contains("visibility") {
                try await initializeRenderer(presentationMode: "prepared")
                readiness = .ready
            } else {
                rendererInitialized = false
                readiness = .directPresentation
            }
            scheduleRefreshIfNeeded()
        } catch {
            guard generation == configurationGeneration else { throw error }
            policy.recordFailure(error, at: Date())
            readiness = .failed
            applyRetryBackoff(error)
            throw error
        }
    }

    private func revealPreparedRenderer() async throws {
        if readiness == .directPresentation {
            policy.beginSession()
            try await initializeRenderer(presentationMode: "visible")
        } else {
            send(command: .object(["name": .string("set_visibility"), "visible": .bool(true)]))
        }
    }

    public func dismiss() {
        guard readiness != .disposed else { return }
        send(command: .object(["name": .string("set_visibility"), "visible": .bool(false)]))
        send(command: .object(["name": .string("flush_capture")]))
        webView.isHidden = true
        isPresented = false
        _ = policy.activateQueuedPreparation()
        if let preparationTask {
            readiness = .preparing
            let taskID = preparationTaskID
            let generation = configurationGeneration
            Task { @MainActor [weak self] in
                let failed: Bool
                do {
                    try await preparationTask.value
                    failed = false
                } catch {
                    failed = true
                }
                guard let self, !self.isPresented,
                      self.configurationGeneration == generation,
                      self.preparationTaskID == taskID || self.preparationTaskID == nil,
                      failed || self.readiness == .preparing else { return }
                self.startHiddenPreparationAfterDismiss()
            }
            return
        }
        startHiddenPreparationAfterDismiss()
    }

    private func startHiddenPreparationAfterDismiss() {
        guard !policy.authorizationBlocked, policy.preparation != nil else {
            readiness = policy.authorizationBlocked ? .failed : .idle
            return
        }
        guard rendererReady else {
            readiness = .idle
            return
        }
        if rendererCapabilities.contains("prepare") && rendererCapabilities.contains("visibility"),
           policy.preparation?.supportsPreparedPresentation == true,
           policy.preparation?.config != nil {
            rendererInitialized = false
            policy.beginSession()
            readiness = .preparing
            let taskID = UUID()
            let generation = configurationGeneration
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.ensurePreparationViewport()
                    try await self.initializeRenderer(presentationMode: "prepared")
                    self.readiness = .ready
                    self.scheduleRefreshIfNeeded()
                } catch {
                    guard self.configurationGeneration == generation, !Task.isCancelled else { throw error }
                    self.policy.recordFailure(error, at: Date())
                    self.readiness = .failed
                    self.applyRetryBackoff(error)
                    throw error
                }
            }
            hiddenPreparationTask = task
            hiddenPreparationTaskID = taskID
            Task { @MainActor [weak self] in
                do {
                    try await task.value
                } catch {
                    guard self?.hiddenPreparationTaskID == taskID else { return }
                    self?.onError(error)
                }
                guard self?.hiddenPreparationTaskID == taskID else { return }
                self?.hiddenPreparationTask = nil
                self?.hiddenPreparationTaskID = nil
            }
        } else {
            rendererInitialized = false
            readiness = .directPresentation
            scheduleRefreshIfNeeded()
        }
    }

    public func updateConfiguration(_ configuration: JourneyConfiguration) {
        let signature = configuration.renderSignature
        guard signature != configurationSignature else { return }
        if rendererInitialized {
            send(command: .object(["name": .string("flush_capture")]))
            send(command: .object(["name": .string("set_visibility"), "visible": .bool(false)]))
        }
        self.configuration = configuration
        configurationSignature = signature
        invalidatePreparedContent(reloadRenderer: true)
        if UIApplication.shared.applicationState == .active { Task { try? await prepare() } }
    }

    public func dispose() {
        guard readiness != .disposed else { return }
        readiness = .disposed
        isPresented = false
        refreshTask?.cancel()
        retryUnlockTask?.cancel()
        preparationTask?.cancel()
        hiddenPreparationTask?.cancel()
        preparationTask = nil
        preparationTaskID = nil
        hiddenPreparationTask = nil
        hiddenPreparationTaskID = nil
        configurationGeneration += 1
        policy.reset()
        lastError = nil
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        controller.unbind(self)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: JourneyBridge.handlerName)
        removePreparationViewport()
        resumeShellWaiters(throwing: JourneyError.unavailable("Journey host was disposed"))
        resumeRenderWaiters(throwing: JourneyError.unavailable("Journey host was disposed"))
    }

    private func performPreparation(generation: Int) async throws {
        let previousReadiness = readiness
        if !isPresented { readiness = .preparing }
        let previousRevisionID = policy.latestRevisionID
        do {
            async let response = client.prepare(for: configuration, knownRevisionID: previousRevisionID)
            async let shell: Void = ensureRendererLoaded()
            let prepared = try await response
            try await shell
            guard generation == configurationGeneration else { throw CancellationError() }
            try policy.recordSuccess(prepared, at: Date(), queueWhilePresented: isPresented)
            retryAvailableAt = nil
            retryError = nil
            if isPresented {
                scheduleRefreshIfNeeded()
                return
            }
            policy.beginSession()
            if prepared.supportsPreparedPresentation && rendererCapabilities.contains("prepare") &&
                rendererCapabilities.contains("visibility") {
                try await initializeRenderer(presentationMode: "prepared")
                readiness = .ready
            } else {
                rendererInitialized = false
                readiness = .directPresentation
            }
            scheduleRefreshIfNeeded()
        } catch {
            guard generation == configurationGeneration else { throw error }
            if isDefinitiveJourneyAuthorizationDenial(error) {
                stopForAuthorizationDenial()
                throw error
            }
            policy.recordFailure(error, at: Date())
            if !isPresented { readiness = policy.preparation == nil ? .failed : previousReadiness }
            applyRetryBackoff(error)
            throw error
        }
    }

    private func ensureRendererLoaded() async throws {
        if !isPresented { try await ensurePreparationViewport() }
        if rendererReady { return }
        webView.load(URLRequest(url: try configuration.resolvedRendererURL()))
        try await withCheckedThrowingContinuation { shellWaiters.append($0) }
    }

    private func initializeRenderer(presentationMode: String) async throws {
        if presentationMode == "prepared" { try await ensurePreparationViewport() }
        guard rendererReady, let config = policy.preparation?.config else {
            throw JourneyError.invalidResponse("Journey preparation is incomplete")
        }
        rendererInitialized = true
        let sessionID = policy.clientSessionID ?? policy.beginSession()
        var payload: [String: JSONValue] = [
            "journeyId": .string(configuration.journeyID), "config": config,
            "capture": configuration.capture?.json ?? .bool(false),
            "initialAnswers": .object(configuration.initialAnswers),
            "initialOptions": .object(configuration.initialOptions), "platform": .string("ios"),
            "sdkVersion": .string(JourneyBridge.sdkVersion),
            "presentationMode": .string(presentationMode), "clientSessionId": .string(sessionID),
        ]
        if policy.preparation?.supportsPreparedPresentation == true,
           let revisionID = policy.preparation?.revisionID {
            payload["revisionId"] = .string(revisionID)
        }
        if let identity = configuration.identity { payload["identity"] = identity.json }
        if let storageKey = configuration.storageKey { payload["storageKey"] = .string(storageKey) }
        if let theme = configuration.theme { payload["theme"] = .string(theme) }
        rendererConfiguration = configuration
        send(type: "initialize", payload: .object(payload))
        try await withCheckedThrowingContinuation { renderWaiters.append($0) }
        queuedCommands.forEach { send(type: "command", payload: $0) }
        queuedCommands.removeAll()
    }

    private func invalidatePreparedContent(reloadRenderer: Bool) {
        refreshTask?.cancel()
        retryUnlockTask?.cancel()
        preparationTask?.cancel()
        hiddenPreparationTask?.cancel()
        preparationTask = nil
        preparationTaskID = nil
        hiddenPreparationTask = nil
        hiddenPreparationTaskID = nil
        configurationGeneration += 1
        policy.reset()
        retryAvailableAt = nil
        retryError = nil
        lastError = nil
        rendererInitialized = false
        queuedCommands.removeAll()
        readiness = .idle
        webView.isHidden = true
        isPresented = false
        if reloadRenderer {
            rendererReady = false
            rendererCapabilities.removeAll()
            webView.stopLoading()
        }
    }

    private func ensurePreparationViewport() async throws {
        guard !isPresented else { return }
        if webView.window != nil && webView.bounds.width > 0 && webView.bounds.height > 0 {
            webView.isHidden = false
            return
        }
        if preparationContainer != nil { removePreparationViewport() }
        for _ in 0..<20 {
            if attachPreparationViewport() { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw JourneyError.unavailable("Journey preparation requires an active app window")
    }

    private func attachPreparationViewport() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }),
              window.bounds.width > 0, window.bounds.height > 0 else { return false }

        let container = UIView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        // A zero-alpha or hidden view can pause WebKit layout and animation frames.
        // Keep a real viewport behind app content with a near-transparent container.
        container.alpha = 0.01
        window.insertSubview(container, at: 0)

        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        webView.isHidden = false
        container.addSubview(webView)
        preparationContainer = container
        return true
    }

    private func removePreparationViewport() {
        guard let preparationContainer else {
            webView.isUserInteractionEnabled = true
            webView.accessibilityElementsHidden = false
            return
        }
        if webView.superview === preparationContainer { webView.removeFromSuperview() }
        preparationContainer.removeFromSuperview()
        self.preparationContainer = nil
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTask?.cancel()
                self?.send(command: .object(["name": .string("flush_capture")]))
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refreshAfterForegroundResume() } })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.releaseHiddenRendererForMemoryPressure() } })
    }

    private func releaseHiddenRendererForMemoryPressure() {
        guard !isPresented, readiness != .disposed else { return }
        refreshTask?.cancel()
        preparationTask?.cancel()
        hiddenPreparationTask?.cancel()
        preparationTask = nil
        preparationTaskID = nil
        hiddenPreparationTask = nil
        hiddenPreparationTaskID = nil
        configurationGeneration += 1
        policy.endRequest()
        rendererReady = false
        rendererInitialized = false
        rendererCapabilities.removeAll()
        queuedCommands.removeAll()
        readiness = policy.authorizationBlocked ? .failed : .idle
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removePreparationViewport()
        resumeShellWaiters(throwing: CancellationError())
        resumeRenderWaiters(throwing: CancellationError())
    }

    private func refreshAfterForegroundResume() async {
        guard readiness != .disposed, policy.needsRefresh(at: Date()) else {
            scheduleRefreshIfNeeded()
            return
        }
        guard policy.canRequest(at: Date()) else { return }
        do { try await prepare(allowAuthorizationRetry: false) } catch { onError(error) }
    }

    private func scheduleRefreshIfNeeded() {
        refreshTask?.cancel()
        guard readiness != .disposed, !policy.authorizationBlocked,
              UIApplication.shared.applicationState == .active else { return }
        guard let refreshAt = policy.automaticRefreshDate() else { return }
        let delay = max(1, refreshAt.timeIntervalSinceNow)
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  UIApplication.shared.applicationState == .active else { return }
            do { try await self.prepare(allowAuthorizationRetry: false) } catch { self.onError(error) }
        }
    }

    private func applyRetryBackoff(_ error: Error) {
        refreshTask?.cancel()
        retryUnlockTask?.cancel()
        guard let retryAt = policy.retryNotBefore else { return }
        retryError = error
        retryAvailableAt = retryAt
        let delay = max(0, retryAt.timeIntervalSinceNow)
        retryUnlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retryAvailableAt = nil
            self?.retryError = nil
        }
    }

    private func withTimeout(seconds: TimeInterval, operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let deadline = JourneyPresentationDeadline(continuation)
            deadline.operationTask = Task { @MainActor in
                do {
                    try await operation()
                    deadline.resolve(.success(()))
                } catch {
                    deadline.resolve(.failure(error))
                }
            }
            deadline.timeoutTask = Task { @MainActor in
                var remaining = seconds
                while remaining > 0, !Task.isCancelled {
                    let wasActive = UIApplication.shared.applicationState == .active
                    let startedAt = Date()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if wasActive && UIApplication.shared.applicationState == .active {
                        remaining -= Date().timeIntervalSince(startedAt)
                    }
                }
                guard !Task.isCancelled else { return }
                deadline.resolve(.failure(JourneyError.unavailable("Journey presentation timed out")))
            }
        }
    }

    private func resumeShellWaiters(throwing error: Error? = nil) {
        let waiters = shellWaiters
        shellWaiters.removeAll()
        waiters.forEach { continuation in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    private func resumeRenderWaiters(throwing error: Error? = nil) {
        let waiters = renderWaiters
        renderWaiters.removeAll()
        waiters.forEach { continuation in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    func send(command: JSONValue) {
        if rendererReady && rendererInitialized { send(type: "command", payload: command) }
        else { queuedCommands.append(command) }
    }

    private func send(type: String, payload: JSONValue) {
        do {
            let script = try JourneyBridge.dispatchScript(type: type, payload: payload)
            webView.evaluateJavaScript(script) { [weak self] _, error in if let error { self?.onError(error) } }
        } catch { onError(error) }
    }

    private func handleCapture(_ payload: [String: JSONValue]) {
        guard let requestID = payload.string("requestId"), let body = payload["body"] else { return }
        let captureConfiguration = rendererConfiguration ?? configuration
        Task {
            do {
                let status = try await client.capture(body, for: captureConfiguration)
                send(type: "capture_response", payload: .object([
                    "requestId": .string(requestID), "ok": .bool(true), "status": .number(Double(status)),
                ]))
            } catch {
                var response: [String: JSONValue] = [
                    "requestId": .string(requestID), "ok": .bool(false),
                    "error": .string(error.localizedDescription),
                ]
                if let httpError = error as? JourneyHTTPError {
                    response["status"] = .number(Double(httpError.statusCode))
                    if let retryAfterMilliseconds = httpError.retryAfterMilliseconds(at: Date()) {
                        response["retryAfterMs"] = .number(Double(retryAfterMilliseconds))
                    }
                }
                send(type: "capture_response", payload: .object(response))
                if isDefinitiveJourneyAuthorizationDenial(error) {
                    stopForAuthorizationDenial()
                }
            }
        }
    }

    private func stopForAuthorizationDenial() {
        send(command: .object(["name": .string("set_visibility"), "visible": .bool(false)]))
        refreshTask?.cancel()
        retryUnlockTask?.cancel()
        preparationTask?.cancel()
        hiddenPreparationTask?.cancel()
        preparationTask = nil
        preparationTaskID = nil
        hiddenPreparationTask = nil
        hiddenPreparationTaskID = nil
        configurationGeneration += 1
        policy.recordFailure(JourneyError.authorizationDenied)
        policy.endRequest()
        retryAvailableAt = nil
        retryError = nil
        rendererInitialized = false
        queuedCommands.removeAll()
        readiness = .failed
        lastError = JourneyError.authorizationDenied
        isPresented = false
        webView.isHidden = true
        removePreparationViewport()
        resumeShellWaiters(throwing: JourneyError.authorizationDenied)
        resumeRenderWaiters(throwing: JourneyError.authorizationDenied)
        onError(JourneyError.authorizationDenied)
    }

    private func handleDiscount(_ payload: [String: JSONValue]) {
        guard let requestID = payload.string("requestId"), let raw = payload["request"],
              let request = JourneyDiscountCodeRequest(rawValue: raw) else { return }
        Task {
            do {
                guard let onDiscountCodeApply else {
                    throw JourneyError.unavailable("No native discount code handler was provided")
                }
                let result = try await onDiscountCodeApply(request)
                send(type: "discount_code_response", payload: .object([
                    "requestId": .string(requestID), "result": result.rawValue,
                ]))
            } catch {
                send(type: "discount_code_response", payload: .object([
                    "requestId": .string(requestID), "error": .string(error.localizedDescription),
                ]))
            }
        }
    }

    private func performHaptic(_ type: JourneyHapticType) {
        switch type {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension JourneyHost: JourneyCommandSink {}

extension JourneyHost: WKScriptMessageHandler, WKNavigationDelegate {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == JourneyBridge.handlerName, let envelope = JourneyBridge.decode(message.body),
              let payload = envelope.payload.objectValue else {
            onError(JourneyError.renderer("The Journey renderer sent an invalid message"))
            return
        }
        switch envelope.type {
        case "ready":
            rendererReady = true
            rendererCapabilities = Set(payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            resumeShellWaiters()
        case "rendered": resumeRenderWaiters()
        case "event":
            if let raw = payload["event"], let event = JourneyEvent(rawValue: raw) { onEvent(event) }
        case "navigation_state":
            controller.updateNavigation(
                stepID: payload.string("stepId") ?? "",
                stepIndex: Int(payload["stepIndex"]?.numberValue ?? 0),
                canGoBack: payload["canGoBack"]?.boolValue ?? false
            )
        case "haptic":
            if let raw = payload.string("type"), let type = JourneyHapticType(rawValue: raw) {
                if let onHaptic { onHaptic(type) } else { performHaptic(type) }
            }
        case "capture_request": handleCapture(payload)
        case "discount_code_request": handleDiscount(payload)
        case "open_url":
            if let value = payload.string("url"), let url = URL(string: value) { onOpenURL(url) }
        case "error":
            let error = JourneyError.renderer(payload.string("message") ?? "Journey renderer error")
            onError(error)
            if payload["recoverable"]?.boolValue == false {
                readiness = .failed
                resumeRenderWaiters(throwing: error)
            }
        default: break
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" || isRendererURL(url) { decisionHandler(.allow) }
        else {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenURL(url) }
            decisionHandler(.cancel)
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rendererReady = false
        rendererInitialized = false
        readiness = .idle
        webView.isHidden = true
        isPresented = false
        webView.reload()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        resumeShellWaiters(throwing: error)
        readiness = .failed
        onError(error)
    }

    private func isRendererURL(_ url: URL) -> Bool {
        guard let expected = try? configuration.resolvedRendererURL() else { return false }
        return url.scheme == expected.scheme && url.host == expected.host &&
            url.port == expected.port && url.path == expected.path
    }
}

@MainActor
public struct JourneyView: View {
    public typealias DiscountHandler = JourneyHost.DiscountHandler
    @StateObject private var host: JourneyHost
    private let loadingView: AnyView?
    private let errorView: ((Error, @escaping () -> Void) -> AnyView)?
    @State private var presentationError: Error?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(host: JourneyHost, loadingView: AnyView? = nil,
                errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil) {
        _host = StateObject(wrappedValue: host)
        self.loadingView = loadingView
        self.errorView = errorView
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
        _host = StateObject(wrappedValue: JourneyHost(
            configuration: configuration, controller: controller, onEvent: onEvent,
            onError: onError, onOpenURL: onOpenURL,
            onDiscountCodeApply: onDiscountCodeApply, onHaptic: onHaptic
        ))
        self.loadingView = loadingView
        self.errorView = errorView
    }

    public var body: some View {
        ZStack {
            loadingBackground.ignoresSafeArea()
            HostedJourneyWebView(host: host).ignoresSafeArea(.container).opacity(host.isPresented ? 1 : 0)
            if !host.isPresented && presentationError == nil {
                if let loadingView { loadingView }
                else if reduceMotion {
                    Image(systemName: "circle.dotted").foregroundStyle(loadingForeground)
                        .accessibilityLabel("Loading Journey")
                } else {
                    ProgressView().tint(loadingForeground).accessibilityLabel("Loading Journey")
                }
            }
            if let presentationError {
                let retry = {
                    guard host.canRetry else { return }
                    self.presentationError = nil
                    Task { await presentHost() }
                }
                if let errorView { errorView(presentationError, retry) }
                else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.circle").font(.title2)
                        Text("Unable to load. Please try again.").font(.headline)
                        Button("Try again", action: retry)
                            .buttonStyle(.borderedProminent)
                            .disabled(!host.canRetry)
                    }
                    .foregroundStyle(loadingForeground)
                    .padding(24)
                }
            }
        }
        .task { await presentHost() }
        .onReceive(host.$lastError) { error in
            if let error { presentationError = error }
        }
        .onDisappear { host.dismiss() }
    }

    private func presentHost() async {
        do { try await host.present() } catch { presentationError = error }
    }

    private var usesDarkLoadingTheme: Bool {
        let theme = host.configuration.theme?.lowercased()
        if theme?.contains("light") == true { return false }
        if theme != nil { return true }
        return colorScheme == .dark
    }

    private var loadingBackground: Color {
        usesDarkLoadingTheme
            ? Color(red: 20 / 255, green: 18 / 255, blue: 16 / 255)
            : Color(uiColor: .systemBackground)
    }

    private var loadingForeground: Color {
        usesDarkLoadingTheme ? .white : .primary
    }
}

private struct HostedJourneyWebView: UIViewRepresentable {
    let host: JourneyHost
    func makeUIView(context: Context) -> WKWebView { host.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

@MainActor
public final class JourneyViewController: UIViewController {
    private let hostingController: UIHostingController<JourneyView>

    public init(host: JourneyHost, loadingView: AnyView? = nil,
                errorView: ((Error, @escaping () -> Void) -> AnyView)? = nil) {
        hostingController = UIHostingController(rootView: JourneyView(
            host: host, loadingView: loadingView, errorView: errorView
        ))
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(
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
        self.init(host: JourneyHost(
            configuration: configuration, controller: controller, onEvent: onEvent,
            onError: onError, onOpenURL: onOpenURL,
            onDiscountCodeApply: onDiscountCodeApply, onHaptic: onHaptic
        ), loadingView: loadingView, errorView: errorView)
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
