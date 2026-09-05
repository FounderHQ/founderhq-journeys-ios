# FounderHQJourneys for iOS

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

`https://github.com/FounderHQ/founderhq-journeys-ios`

Select version **0.1.1** or later. Swift Package Manager is the recommended installation method.

For CocoaPods:

```ruby
pod 'FounderHQJourneys', '~> 0.1.1'
```

For installation directly from the release tag:

```ruby
pod 'FounderHQJourneys', :git => 'https://github.com/FounderHQ/founderhq-journeys-ios.git', :tag => 'v0.1.1'
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

The SDK includes first-paint loading, app lifecycle capture flushing, native
haptics, typed events and discounts, external/deep-link handling, local test
configs, dynamic capture context, and custom capture transports.
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
