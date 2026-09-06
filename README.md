# FounderHQJourneys for iOS

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

`https://github.com/FounderHQ/founderhq-journeys-ios`

Select version **0.8.0** or later. Swift Package Manager is the recommended installation method.

For CocoaPods:

```ruby
pod 'FounderHQJourneys', '~> 0.8.0'
```

For installation directly from the release tag:

```ruby
pod 'FounderHQJourneys', :git => 'https://github.com/FounderHQ/founderhq-journeys-ios.git', :tag => 'v0.8.0'
```

Both installation methods use the same Swift implementation. Requires iOS 15 or later.

## Usage

`FounderHQJourneys` is a Swift Package for presenting published FounderHQ
Journeys from SwiftUI or UIKit. It supports iOS 15 and later.

```swift
import FounderHQJourneys

struct OnboardingView: View {
    private let controller = JourneyController()

    var body: some View {
        JourneyView(
            configuration: JourneyConfiguration(
                apiKey: "fhq_pk_...",
                journeyID: "journey_id",
                identity: JourneyIdentity(externalID: "customer_id")
            ),
            controller: controller,
            onEvent: { event in
                if event.type == .complete {
                    // Continue into the app.
                }
            }
        )
    }
}
```

UIKit consumers can present `JourneyViewController`. `JourneyController`
provides `goNext`, `goBack`, `goToStep`, `setAnswer`, `flushCapture`, and
`reload` commands.

For instant presentation, keep one `JourneyHost` for each place that can show a
Journey and prepare it while the preceding screen is visible:

```swift
@State private var showJourney = false
@StateObject private var host = JourneyHost(configuration: .init(
    apiKey: "fhq_pk_...",
    journeyID: "journey_id",
    identity: JourneyIdentity(externalID: "customer_id")
))

var body: some View {
    Button("Start") { showJourney = true }
        .task { try? await host.prepare() }
        .fullScreenCover(isPresented: $showJourney) {
            JourneyView(host: host)
        }
}
```

`prepare()` loads the published configuration and renderer in parallel. A
prepared renderer stays hidden and emits no presentation analytics until
`present()` makes it visible. `JourneyView(host:)` calls `present()` when it
appears and `dismiss()` when it leaves. Call `updateConfiguration(_:)` after
identity or Journey changes, and `dispose()` when the owning flow is finished.
One host owns one renderer for its lifetime; do not share a host between two
simultaneously visible surfaces.

The SDK includes first-paint loading, app lifecycle capture flushing, native
haptics, typed events and discounts, external/deep-link handling, local test
configs and custom capture transports. Capture request bodies are forwarded
unchanged so the renderer and server retain the same event payload.
`JourneyController` publishes `canGoBack`, `currentStepID`, and
`currentStepIndex`. SwiftUI and UIKit entry points accept custom loading and
error views.

## Screen edges and system bars

Journey backgrounds extend behind the status bar and home-indicator area.
The web renderer uses `viewport-fit=cover` and `env(safe-area-inset-*)` to
keep controls inside the device safe area, including headerless info pages.
Do not add another safe-area inset around `JourneyView`. App-owned overlays
such as a Close button should remain in the host's safe area.

The host app controls status-bar and home-indicator visibility. The SDK does
not draw an imitation home indicator or force system overlays to hide.

## Release notes

### 0.8.0

- Journey API requests and renderer pages use `https://app.getfounderhq.com`. The analytics ingest host is reserved for Events.

### API and renderer hosts

Production API requests use `https://app.getfounderhq.com`. The native WebView
loads `https://app.getfounderhq.com/embed/journeys/native`, where the renderer
and its assets are hosted. Custom/local API origins retain a renderer on that
origin by default; an explicit renderer URL overrides it.
