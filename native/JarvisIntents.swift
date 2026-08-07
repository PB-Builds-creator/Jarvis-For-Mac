import AppIntents
import Foundation

private enum JarvisIntentNotification {
    static let talk = Notification.Name("dev.pbbuilds.jarvis.intent.talk")
    static let ask = Notification.Name("dev.pbbuilds.jarvis.intent.ask")
    static let status = Notification.Name("dev.pbbuilds.jarvis.intent.status")
    static let privateMode = Notification.Name("dev.pbbuilds.jarvis.intent.private-mode")
    static let remember = Notification.Name("dev.pbbuilds.jarvis.intent.remember")
    static let tradingReview = Notification.Name(
        "dev.pbbuilds.jarvis.captureTradingViewReview"
    )
}

private func postJarvisIntent(
    _ name: Notification.Name,
    userInfo: [String: Any] = [:]
) {
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: userInfo,
        deliverImmediately: true
    )
}

struct TalkToJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Jarvis"
    static let description = IntentDescription(
        "Starts Jarvis voice input using the preferred microphone."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        postJarvisIntent(JarvisIntentNotification.talk)
        return .result(dialog: "Jarvis is ready to listen.")
    }
}

struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis"
    static let description = IntentDescription(
        "Sends a request to Jarvis for review before any action runs."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Request")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleaned = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw $request.needsValueError("What should Jarvis do?")
        }
        postJarvisIntent(
            JarvisIntentNotification.ask,
            userInfo: ["request": String(cleaned.prefix(4_000))]
        )
        return .result(dialog: "Jarvis opened the request for review.")
    }
}

struct ScanTradingViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan TradingView"
    static let description = IntentDescription(
        "Captures the guarded four-timeframe MGC and DXY review."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        postJarvisIntent(JarvisIntentNotification.tradingReview)
        return .result(dialog: "Jarvis started the guarded TradingView review.")
    }
}

struct ShowJarvisStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Jarvis Status"
    static let description = IntentDescription(
        "Shows voice, microphone, permissions, and local intelligence health."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        postJarvisIntent(JarvisIntentNotification.status)
        return .result(dialog: "Jarvis status is open.")
    }
}

struct SetJarvisPrivateModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Jarvis Private Mode"
    static let description = IntentDescription(
        "Turns fully local Private Mode on or off."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Private Mode")
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        postJarvisIntent(
            JarvisIntentNotification.privateMode,
            userInfo: ["enabled": enabled]
        )
        return .result(
            dialog: enabled
                ? "Jarvis Private Mode is on."
                : "Jarvis Private Mode is off."
        )
    }
}

struct RememberWithJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember with Jarvis"
    static let description = IntentDescription(
        "Stores a private local memory."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw $text.needsValueError("What should Jarvis remember?")
        }
        postJarvisIntent(
            JarvisIntentNotification.remember,
            userInfo: ["text": String(cleaned.prefix(10_000))]
        )
        return .result(dialog: "Jarvis stored that locally.")
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToJarvisIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Talk to Jarvis",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Jarvis",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ScanTradingViewIntent(),
            phrases: [
                "Scan TradingView with \(.applicationName)",
                "Run my chart scan with \(.applicationName)",
            ],
            shortTitle: "Scan TradingView",
            systemImageName: "chart.xyaxis.line"
        )
        AppShortcut(
            intent: ShowJarvisStatusIntent(),
            phrases: ["Show \(.applicationName) status"],
            shortTitle: "Jarvis Status",
            systemImageName: "checkmark.circle"
        )
    }
}
