import Foundation
import Darwin
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import CoreAudio
import CoreGraphics
import LocalAuthentication
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import Speech

_ = umask(0o077)

private let jarvisBundleIdentifier = "dev.pbbuilds.jarvis"
private var approvedChromeProfileEmail: String {
    if let configured = ProcessInfo.processInfo.environment["JARVIS_CHROME_PROFILE_EMAIL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty {
        return configured
    }
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Jarvis/Data/no_api_config.json")
    guard let data = try? Data(contentsOf: configURL),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    return (values["approved_chrome_profile_email"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
private let voiceShortcutDefaultsKey = "voiceShortcutEnabled"
private let wakeWordDefaultsKey = "wakeWordEnabled"
private let ownerVoiceLockDefaultsKey = "ownerVoiceLockEnabled"
private let autonomousActionsDefaultsKey = "autonomousStandardActionsEnabled"
private let spokenResponsesDefaultsKey = "spokenResponsesEnabled"
private let conversationFollowupsDefaultsKey = "conversationFollowupsEnabled"
private let persistentPresenceDefaultsKey = "persistentPresenceEnabled"
private let tradingViewReviewDiagnosticNotification = Notification.Name(
    "dev.pbbuilds.jarvis.captureTradingViewReview"
)
private let tradingViewNYFibDiagnosticNotification = Notification.Name(
    "dev.pbbuilds.jarvis.markTradingViewNYRangeFib"
)
private let activeWindowCaptureRequestNotification = Notification.Name(
    "dev.pbbuilds.jarvis.captureActiveWindowRequest"
)
private let liveVoiceDiagnosticNotification = Notification.Name(
    "dev.pbbuilds.jarvis.runLiveVoiceDiagnostic"
)
private let presencePreviewNotification = Notification.Name(
    "dev.pbbuilds.jarvis.previewPresence"
)
private let testSpokenResponseNotification = Notification.Name(
    "dev.pbbuilds.jarvis.testSpokenResponse"
)
private let intentTalkNotification = Notification.Name(
    "dev.pbbuilds.jarvis.intent.talk"
)
private let intentAskNotification = Notification.Name(
    "dev.pbbuilds.jarvis.intent.ask"
)
private let intentStatusNotification = Notification.Name(
    "dev.pbbuilds.jarvis.intent.status"
)
private let intentPrivateModeNotification = Notification.Name(
    "dev.pbbuilds.jarvis.intent.private-mode"
)
private let intentRememberNotification = Notification.Name(
    "dev.pbbuilds.jarvis.intent.remember"
)
private let runLiveVoiceDiagnosticAtLaunch = CommandLine.arguments.contains(
    "--run-live-voice-test"
)
private let voiceShortCommandSilenceSeconds: Double = 0.95
private let voiceMediumCommandSilenceSeconds: Double = 1.25
private let voiceLongCommandSilenceSeconds: Double = 1.55
private let voiceIncompleteCommandSilenceSeconds: Double = 2.20
private let voiceWakeOnlyGraceSeconds: Double = 1.70
private let voiceTranscriptInactivitySeconds: Double = 0.65
// Bound end-of-command latency when a noisy room keeps the lightweight RMS
// detector active after Speech has stopped changing. This does not run another
// model and therefore adds no steady-state CPU or GPU cost.
private let voiceTranscriptHardStopSeconds: Double = 2.00
private let voiceNoisyRoomTranscriptGraceSeconds: Double = 0.20
private let voiceMinimumRecognizedSeconds: Double = 0.70
private let voiceNoSpeechTimeoutSeconds: Double = 3.0
// A television or nearby conversation can look acoustically active without
// yielding a usable near-field command. Bound that state separately so an
// explicit recording never lingers until the 30-second safety ceiling.
private let voiceUnrecognizedAudioTimeoutSeconds: Double = 4.0
private let voiceMaximumCommandSeconds: Double = 30.0
private let voiceAcousticFallbackSilenceSeconds: Double = 1.35
private let voiceMinimumAcousticSpeechSeconds: Double = 1.0
private let voiceNoiseCalibrationSeconds: Double = 0.45
private let voiceSignalMarginDB: Float = 4.0
private let voiceSignalReleaseMarginDB: Float = 2.5
private let voiceAcousticDetectionMarginDB: Float = 5.0
private let voiceMinimumDetectionBuffers = 2
private let voiceReportedFinalSilenceSeconds: Double = 1.0
private let voiceReportedFinalAcousticQuietSeconds: Double = 0.35
private let voiceFinalizationTimeoutSeconds: Double = 1.10
private let voiceModernStreamingFinalizationTimeoutSeconds: Double = 0.85
private let whisperFallbackExecutable = "/opt/homebrew/bin/whisper-cli"
private let whisperFallbackModelRelativePath =
    "Jarvis/Models/Whisper/ggml-large-v3-turbo-q5_0.bin"
private let wakeHealthCheckIntervalSeconds: Double = 12.0
private let wakeAudioStallTimeoutSeconds: Double = 4.0
private let wakeSessionRefreshSeconds: Double = 600.0
private let baseVoiceContextualPhrases = [
    "Jarvis", "ChatGPT", "Google Chrome", "TradingView", "Trading View",
    "Farm RPG", "Crunchyroll", "Hulu", "Netflix", "Snapchat", "Instagram",
    "Fidelity", "Xbox", "Continue Watching", "New York range", "fair value gap",
    "MGC", "MGCQ2026", "COMEX Mini Gold", "DXY", "U.S. Dollar Index", "VWAP",
    "analyze this chart", "summarize this window", "send this to Work",
    "scan Chrome", "scan Safari", "scan Notes", "scan Discord",
    "scan TradingView once", "scan TradingView one time",
    "scan the TradingView window once", "capture TradingView once",
    "scan this chart once", "scan the current window once",
    "capture an app window",
    "do today's technical analysis", "do today's scans", "scan today's market",
    "read my backtest", "scan my backtest", "analyze my back testing",
    "use my strat", "use my strategy", "mark out NY", "Fib NY",
    "mark the New York range", "draw my New York Fib", "draw my Fibonacci levels",
    "four-hour structure", "Razer Seiren V3 Mini", "Siri",
]
private let ownerVoiceEnrollmentPrompts = [
    "Jarvis, scan TradingView once.",
    "Jarvis, open Discord and wait.",
    "Jarvis, tell me what is on my screen.",
    "Jarvis, prepare my technical analysis.",
    "Jarvis, this is my regular speaking voice.",
]
private var voiceContextualPhrases: [String] {
    var phrases = baseVoiceContextualPhrases
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Jarvis/Data/voice-context.json")
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let custom = payload["phrases"] as? [String] else {
        return phrases
    }
    var seen = Set(phrases.map {
        $0.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    })
    for raw in custom.prefix(200) {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 120 else { continue }
        let folded = phrase.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if seen.insert(folded).inserted {
            phrases.append(phrase)
        }
    }
    return phrases
}
private func learnedVoiceReplacements() -> [(String, String)] {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Jarvis/Data/voice-context.json")
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let replacements = payload["replacements"] as? [[String: Any]] else {
        return []
    }
    return replacements.prefix(200).compactMap { item in
        guard let source = item["phrase"] as? String,
              let replacement = item["replacement"] as? String else { return nil }
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty,
              !cleanReplacement.isEmpty,
              cleanSource.count <= 120,
              cleanReplacement.count <= 120 else { return nil }
        return (cleanSource, cleanReplacement)
    }
}
private let voiceDiagnosticsLock = NSLock()
private let privateLogMaximumBytes = 2_000_000

private enum LocalWhisperFallback {
    static var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(whisperFallbackModelRelativePath)
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: whisperFallbackExecutable)
            && FileManager.default.fileExists(atPath: modelURL.path)
    }

    static func transcribe(fileURL: URL) throws -> String {
        guard isAvailable else {
            throw VoiceSessionError.transcriptionFailed(
                "The local Whisper recovery model is not installed."
            )
        }
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [
            fileURL.path, wavURL.path,
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
        ]
        let converterError = Pipe()
        converter.standardOutput = Pipe()
        converter.standardError = converterError
        try converter.run()
        converter.waitUntilExit()
        guard converter.terminationStatus == 0 else {
            let detail = String(
                data: converterError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "conversion failed"
            throw VoiceSessionError.transcriptionFailed(detail)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperFallbackExecutable)
        process.arguments = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-l", "en",
            "-t", "4",
            "-nt",
            "-np",
            "--prompt",
            "Jarvis, Siri, TradingView, MGC, DXY, VWAP, New York range, "
                + "fair value gap, Fibonacci, ChatGPT",
        ]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "recognition failed"
            throw VoiceSessionError.transcriptionFailed(detail)
        }
        let transcript = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !transcript.isEmpty else { throw VoiceSessionError.noSpeech }
        return transcript
    }
}

private func preparePrivateLog(_ logURL: URL) {
    let fileManager = FileManager.default
    let directory = logURL.deletingLastPathComponent()
    try? fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
       let size = attributes[.size] as? NSNumber,
       size.intValue > privateLogMaximumBytes {
        let previous = logURL.appendingPathExtension("previous")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: logURL, to: previous)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
    }
    if !fileManager.fileExists(atPath: logURL.path) {
        fileManager.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
}
private let ignoredWindowOwners: Set<String> = [
    "Jarvis",
    "JarvisMenuBar",
    "Dock",
    "Window Server",
    "SystemUIServer",
    "Control Center",
    "Notification Center",
]
private let accessibilitySceneCacheLifetimeSeconds: TimeInterval = 12.0
private let accessibilitySceneMaxElements = 1800
private let accessibilitySceneMaxContextLabels = 78

private struct CachedAccessibilityEntry {
    let element: AXUIElement
    let fields: [String]
}

private struct CachedAccessibilityScene {
    let pid: pid_t
    let createdAt: TimeInterval
    let entries: [CachedAccessibilityEntry]
    let contextLines: [String]
}

private final class WorkspaceLaunchState: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    var application: NSRunningApplication?
    var error: Error?

    func finish(application: NSRunningApplication?, error: Error?) {
        self.application = application
        self.error = error
        completed.signal()
    }
}

private func currentThermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

private func navigationNeedsVisibleUI(_ transcript: String) -> Bool {
    let lowered = transcript.lowercased()
    let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("open ") || trimmed.hasPrefix("launch ")
        || trimmed.hasPrefix("switch to ") || trimmed.hasPrefix("go to ") {
        return false
    }
    return [
        "click", "focus", "find", "search", "select", "choose", "press",
        "scroll", "verify", "make sure", "ensure", "visible control",
    ].contains(where: lowered.contains)
}

private func logVoiceDiagnostic(_ event: String) {
    voiceDiagnosticsLock.lock()
    defer { voiceDiagnosticsLock.unlock() }
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Jarvis/Data/logs/voice-diagnostics.log")
    preparePrivateLog(logURL)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let record = "[\(timestamp)] \(event)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(record.utf8))
        try? handle.close()
    }
}

private func writeJSON(_ object: Any, exitCode: Int32 = 0) -> Never {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Could not encode JSON output: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
    exit(exitCode)
}

private func compactJSONString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let value = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return value
}

private func failCLI(_ message: String, exitCode: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(exitCode)
}

private func loginItemStatusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
        return "notRegistered"
    case .enabled:
        return "enabled"
    case .requiresApproval:
        return "requiresApproval"
    case .notFound:
        return "notFound"
    @unknown default:
        return "unknown"
    }
}

private func loginItemPlan(statusName: String, enable: Bool) -> String {
    if enable {
        return statusName == "notRegistered" || statusName == "notFound"
            ? "register" : "none"
    }
    return statusName == "notRegistered" || statusName == "notFound"
        ? "none" : "unregister"
}

private func microphoneAuthorizationName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
        return "notDetermined"
    case .restricted:
        return "restricted"
    case .denied:
        return "denied"
    case .authorized:
        return "authorized"
    @unknown default:
        return "unknown"
    }
}

private func speechAuthorizationName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
        return "notDetermined"
    case .denied:
        return "denied"
    case .restricted:
        return "restricted"
    case .authorized:
        return "authorized"
    @unknown default:
        return "unknown"
    }
}

private func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &name) { pointer in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return name as String?
}

private func audioInputDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }
    var devices = [AudioDeviceID](
        repeating: AudioDeviceID(kAudioObjectUnknown),
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    let status = devices.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            buffer.baseAddress!
        )
    }
    guard status == noErr else { return [] }
    return devices.filter { deviceID in
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID, &streamAddress, 0, nil, &streamSize
        ) == noErr && streamSize > 0
    }
}

private func preferredRazerMicrophoneID() -> AudioDeviceID? {
    audioInputDeviceIDs().first { deviceID in
        guard let name = audioDeviceName(deviceID)?.lowercased() else { return false }
        return name.contains("razer")
            && (name.contains("seiren") || name.contains("seian"))
            && name.contains("mini")
    }
}

private func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
}

private func defaultInputDeviceName() -> String {
    guard let deviceID = defaultInputDeviceID() else { return "Unavailable" }
    return audioDeviceName(deviceID) ?? "Unknown"
}

@discardableResult
private func makeRazerMicrophoneDefaultInput() -> Bool {
    guard var preferredID = preferredRazerMicrophoneID() else { return false }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    if defaultInputDeviceID() == preferredID {
        return true
    }
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &preferredID
    )
    if status == noErr {
        let deadline = Date().addingTimeInterval(0.75)
        while defaultInputDeviceID() != preferredID, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard defaultInputDeviceID() == preferredID else {
            logVoiceDiagnostic("preferred_microphone_unconfirmed")
            return false
        }
        logVoiceDiagnostic(
            "preferred_microphone_selected name=\(audioDeviceName(preferredID) ?? "Razer Seiren Mini")"
        )
        return true
    }
    logVoiceDiagnostic("preferred_microphone_failed status=\(status)")
    return false
}

private func errorDiagnostic(_ error: Error) -> String {
    let value = error as NSError
    let detail = value.localizedDescription
        .replacingOccurrences(of: "\n", with: " ")
    return "domain=\(value.domain) code=\(value.code) detail=" + String(detail.prefix(240))
}

@available(macOS 26.0, *)
private func configuredModernSpeechTranscriber() async throws -> SpeechTranscriber {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US")
          ) else {
        throw VoiceSessionError.recognizerUnavailable
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let status = await AssetInventory.status(forModules: [transcriber])
    if status == .unsupported {
        throw VoiceSessionError.recognizerUnavailable
    }
    if status != .installed,
       let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber]
       ) {
        try await request.downloadAndInstall()
    }
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
        throw VoiceSessionError.recognizerUnavailable
    }
    _ = try? await AssetInventory.reserve(locale: locale)
    return transcriber
}

@available(macOS 26.0, *)
private func transcribeWithModernSpeech(fileURL: URL) async throws -> String {
    let transcriber = try await configuredModernSpeechTranscriber()
    let context = AnalysisContext()
    context.contextualStrings[.general] = voiceContextualPhrases
    let analyzer = SpeechAnalyzer(
        modules: [transcriber],
        options: SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .lingering
        )
    )
    try await analyzer.setContext(context)
    let resultsTask = Task<String, Error> {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !transcript.isEmpty { transcript += " " }
            transcript += text
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    do {
        let file = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await resultsTask.value
    } catch {
        resultsTask.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
    }
}

private func prewarmModernSpeechRecognition() {
    guard #available(macOS 26.0, *) else { return }
    Task(priority: .utility) {
        do {
            let base = try await configuredModernSpeechTranscriber()
            guard let locale = base.selectedLocales.first else {
                throw VoiceSessionError.recognizerUnavailable
            }
            let progressive = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [progressive]
            )
            logVoiceDiagnostic(
                "modern_speech_ready rate=\(Int(format?.sampleRate ?? 0)) "
                + "channels=\(format?.channelCount ?? 0)"
            )
        } catch {
            logVoiceDiagnostic("modern_speech_unavailable " + errorDiagnostic(error))
        }
    }
}

private func runModernSpeechFileTest(_ path: String) -> Never {
    guard #available(macOS 26.0, *) else {
        failCLI("Modern speech recognition requires macOS 26 or newer.")
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        failCLI("The requested audio file does not exist.")
    }
    let started = Date()
    Task {
        do {
            let transcript = try await transcribeWithModernSpeech(fileURL: url)
            writeJSON([
                "ok": !transcript.isEmpty,
                "transcript": transcript,
                "duration_ms": Int(Date().timeIntervalSince(started) * 1_000),
            ], exitCode: transcript.isEmpty ? 1 : 0)
        } catch {
            failCLI("Modern speech transcription failed: \(errorDiagnostic(error))")
        }
    }
    RunLoop.current.run()
    fatalError("The modern speech test run loop exited unexpectedly.")
}

private func wakeCommandAfterWakeWord(_ transcript: String) -> String? {
    if UserDefaults.standard.bool(forKey: ownerVoiceLockDefaultsKey),
       transcript.range(
            of: #"(?i)(?<![A-Za-z])(?:jarvis|jervis|gan|garvis|darvis|jarbis|jarves)(?![A-Za-z])[\s,;:\-]{1,8}(?:trading\s*(?:view|few|you)|tradingview)[\s,;:\-]{1,8}(?:once|ones|one\s+time)\b"#,
            options: .regularExpression
       ) != nil {
        // Both "scan" and the wake word can be partially masked by a show.
        // This narrowly scoped, owner-gated phrase still produces the same
        // confirmation-required one-shot TradingView capture.
        return "scan TradingView once"
    }
    // Accept only a narrow set of common on-device phonetic transcriptions.
    // Do not accept broad words such as "service", which would create false wakes.
    let exactRange = transcript.range(
        of: #"(?i)(?<![A-Za-z])(?:jarvis|jervis|jar[ -]?vus|jar[ -]vis)(?![A-Za-z])"#,
        options: .regularExpression
    )
    // In a room with a show playing, Apple Speech can collapse the wake word
    // while still hearing the command correctly (for example, "Gan, scan…").
    // Permit only observed close variants immediately followed by a real command
    // anchor, and only while the enrolled owner-voice gate is enabled. The
    // speaker check still happens before any request is accepted.
    let contextualRange: Range<String.Index>? = {
        guard UserDefaults.standard.bool(forKey: ownerVoiceLockDefaultsKey) else {
            return nil
        }
        return transcript.range(
            of: #"(?i)(?<![A-Za-z])(?:gan|garvis|darvis|jarbis|jarves)(?![A-Za-z])(?=[\s,;:\-]{1,8}(?:open|scan|capture|show|tell|read|remember|explain|prepare|send|go|switch|close|create|move|start|stop|what|why|how|can|do)\b)"#,
            options: .regularExpression
        )
    }()
    guard let range = exactRange ?? contextualRange else {
        return nil
    }
    let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    var command = String(transcript[range.upperBound...])
        .trimmingCharacters(in: trimSet)
    if command.lowercased().hasPrefix("and ") {
        command = String(command.dropFirst(4))
            .trimmingCharacters(in: trimSet)
    }
    return command
}

private func isSiriWakeTranscript(_ transcript: String) -> Bool {
    let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    let cleaned = transcript.trimmingCharacters(in: trimSet).lowercased()
    return cleaned == "siri" || cleaned.hasPrefix("siri ")
}

// Endpointing uses the voice band above the Razer's measured low-frequency
// rumble. Recognition and recorded audio remain completely unfiltered.
private let voiceHighPassFrequencyHz: Double = 180.0

private final class VoiceHighPassFilter {
    private let alpha: Float
    private var previousInputStageOne: [Float]
    private var previousOutputStageOne: [Float]
    private var previousInputStageTwo: [Float]
    private var previousOutputStageTwo: [Float]

    init(format: AVAudioFormat) {
        let channelCount = max(1, Int(format.channelCount))
        let sampleInterval = 1.0 / max(1.0, format.sampleRate)
        let timeConstant = 1.0 / (2.0 * Double.pi * voiceHighPassFrequencyHz)
        alpha = Float(timeConstant / (timeConstant + sampleInterval))
        previousInputStageOne = Array(repeating: 0, count: channelCount)
        previousOutputStageOne = Array(repeating: 0, count: channelCount)
        previousInputStageTwo = Array(repeating: 0, count: channelCount)
        previousOutputStageTwo = Array(repeating: 0, count: channelCount)
    }

    func filteredLevelDB(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = min(
            Int(buffer.format.channelCount),
            previousInputStageOne.count
        )
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return nil }
        var squareSum: Double = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            var inputOne = previousInputStageOne[channel]
            var outputOne = previousOutputStageOne[channel]
            var inputTwo = previousInputStageTwo[channel]
            var outputTwo = previousOutputStageTwo[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                let stageOne = alpha * (outputOne + sample - inputOne)
                inputOne = sample
                outputOne = stageOne
                let stageTwo = alpha * (outputTwo + stageOne - inputTwo)
                inputTwo = stageOne
                outputTwo = stageTwo
                squareSum += Double(stageTwo * stageTwo)
            }
            previousInputStageOne[channel] = inputOne
            previousOutputStageOne[channel] = outputOne
            previousInputStageTwo[channel] = inputTwo
            previousOutputStageTwo[channel] = outputTwo
        }
        let meanSquare = max(
            squareSum / Double(channelCount * frameCount),
            1e-12
        )
        return Float(10.0 * log10(meanSquare))
    }
}

private func copySpeechBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameLength
    ), let source = buffer.floatChannelData,
       let destination = copy.floatChannelData else { return nil }
    copy.frameLength = buffer.frameLength
    let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
    for channel in 0..<Int(buffer.format.channelCount) {
        memcpy(destination[channel], source[channel], byteCount)
    }
    return copy
}

private func convertSpeechBuffer(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
) throws -> AVAudioPCMBuffer? {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(
        max(1, ceil(Double(buffer.frameLength) * ratio) + 32)
    )
    guard let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: capacity
    ) else { return nil }
    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) {
        _, inputStatus in
        if suppliedInput {
            inputStatus.pointee = .noDataNow
            return nil
        }
        suppliedInput = true
        inputStatus.pointee = .haveData
        return buffer
    }
    if status == .error {
        throw conversionError ?? NSError(
            domain: jarvisBundleIdentifier,
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "Live speech audio conversion failed."]
        )
    }
    return output.frameLength > 0 ? output : nil
}

private func transcriptWords(_ transcript: String) -> [Substring] {
    transcript.split { !$0.isLetter && !$0.isNumber }
}

private func transcriptNeedsContinuation(_ transcript: String) -> Bool {
    guard let last = transcriptWords(transcript).last?.lowercased() else { return false }
    return [
        "a", "an", "and", "at", "before", "for", "from", "in", "into", "of",
        "on", "or", "the", "then", "to", "with",
    ].contains(last)
}

private func commandEndSilenceSeconds(_ transcript: String) -> Double {
    if transcriptNeedsContinuation(transcript) {
        return voiceIncompleteCommandSilenceSeconds
    }
    switch transcriptWords(transcript).count {
    case 0...3:
        return voiceShortCommandSilenceSeconds
    case 4...9:
        return voiceMediumCommandSilenceSeconds
    default:
        return voiceLongCommandSilenceSeconds
    }
}

private func transcriptEndSilenceSeconds(_ transcript: String) -> Double {
    min(
        commandEndSilenceSeconds(transcript) + voiceNoisyRoomTranscriptGraceSeconds,
        voiceTranscriptHardStopSeconds
    )
}

private func shouldFinalizeRecognizedCommand(
    transcript: String,
    acousticQuietFor: Double,
    transcriptQuietFor: Double,
    recognizedFor: Double
) -> Bool {
    guard !transcript.isEmpty, recognizedFor >= voiceMinimumRecognizedSeconds else {
        return false
    }
    // Once the calibrated near-field signal has gone quiet, finish even if a
    // television keeps causing low-confidence transcript revisions. Transcript
    // stability remains the fallback for rooms whose acoustic edge is unclear.
    if acousticQuietFor >= commandEndSilenceSeconds(transcript) {
        return true
    }
    guard transcriptQuietFor >= voiceTranscriptInactivitySeconds else { return false }
    return transcriptQuietFor >= transcriptEndSilenceSeconds(transcript)
}

private func shouldFinalizeAcousticFallback(
    heardAcousticSpeech: Bool,
    acousticQuietFor: Double,
    acousticSpeechFor: Double
) -> Bool {
    heardAcousticSpeech
        && acousticSpeechFor >= voiceMinimumAcousticSpeechSeconds
        && acousticQuietFor >= voiceAcousticFallbackSilenceSeconds
}

private func shouldFinalizeUnrecognizedAudio(
    hasRecognizedSpeech: Bool,
    elapsed: Double
) -> Bool {
    !hasRecognizedSpeech && elapsed >= voiceUnrecognizedAudioTimeoutSeconds
}

private func shouldFinalizeReportedFinal(
    transcript: String,
    isFinal: Bool,
    acousticQuietFor: Double,
    transcriptQuietFor: Double
) -> Bool {
    isFinal
        && !transcript.isEmpty
        && !transcriptNeedsContinuation(transcript)
        && acousticQuietFor >= voiceReportedFinalAcousticQuietSeconds
        && transcriptQuietFor >= voiceReportedFinalSilenceSeconds
}

private func preferredTranscript(
    current: String,
    candidate: String,
    isFinal: Bool
) -> String {
    let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return current }
    guard !current.isEmpty else { return cleaned }
    let currentWords = transcriptWords(current).count
    let candidateWords = transcriptWords(cleaned).count
    let currentFolded = current.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let candidateFolded = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

    if currentFolded.hasPrefix(candidateFolded), candidateWords < currentWords {
        return current
    }
    if candidateWords > currentWords || (candidateWords == currentWords && cleaned.count >= current.count) {
        return cleaned
    }
    if isFinal, candidateWords + 1 >= currentWords {
        return cleaned
    }
    return current
}

private func normalizeRecognizedTranscript(_ transcript: String) -> String {
    var cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
        (#"(?i)\bdrama fibonacci\b"#, "draw my Fibonacci"),
        (#"(?i)\b(?:4|four)[ -]?hours? structure\b"#, "4-hour structure"),
        (
            #"(?i)\b(?:trading|training|treating)\s+(?:view|few|you|vue)\b"#,
            "TradingView"
        ),
        (#"(?i)\b(?:skin|scam)\s+(?=TradingView\b)"#, "scan "),
        (#"(?i)\bTradingView\s+(?:ones|wants)\b"#, "TradingView once"),
        (#"(?i)\bjarvis work\b"#, "Jarvis Work"),
    ]
    for (pattern, replacement) in replacements {
        cleaned = cleaned.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    for (source, replacement) in learnedVoiceReplacements() {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)(?<![A-Za-z0-9])\#(escaped)(?![A-Za-z0-9])"#,
            with: replacement,
            options: .regularExpression
        )
    }
    return cleaned
}

private func voiceTranscriptReview(
    heard: String,
    interpreted: String
) -> String {
    let heardFolded = heard.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
    )
    let interpretedFolded = interpreted.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
    )
    if heardFolded == interpretedFolded {
        return "I heard:\n\n“\(heard)”"
    }
    return (
        "I heard:\n\n“\(heard)”\n\n"
        + "Using the active app and Jarvis command context, I interpreted that as:\n\n"
        + "“\(interpreted)”"
    )
}

private func voiceCommandCandidateScore(_ transcript: String) -> Int {
    let normalized = normalizeRecognizedTranscript(transcript).lowercased()
    guard !normalized.isEmpty else { return 0 }
    var score = min(5, transcriptWords(normalized).count)
    if normalized.range(
        of: #"\b(?:scan|capture|review|analyze|analyse|open|launch|send|summarize|mark|draw)\b"#,
        options: .regularExpression
    ) != nil {
        score += 4
    }
    if normalized.range(
        of: #"\b(?:tradingview|chrome|safari|notes|discord|finder|mail|calendar|terminal|chatgpt|codex)\b"#,
        options: .regularExpression
    ) != nil {
        score += 5
    }
    if normalized.range(
        of: #"\b(?:once|one time|single|current window|current chart|this window|this chart)\b"#,
        options: .regularExpression
    ) != nil {
        score += 3
    }
    if normalized.range(
        of: #"\b(?:today'?s scans|technical analysis|backtest|new york|fib|fibonacci)\b"#,
        options: .regularExpression
    ) != nil {
        score += 4
    }
    return score
}

private func preferredRecognitionCandidate(
    modern: String,
    legacy: String
) -> (transcript: String, engine: String) {
    let cleanModern = modern.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanLegacy = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleanModern.isEmpty {
        return (cleanLegacy, "legacy")
    }
    if cleanLegacy.isEmpty {
        return (cleanModern, "speech_analyzer")
    }
    let modernScore = voiceCommandCandidateScore(cleanModern)
    let legacyScore = voiceCommandCandidateScore(cleanLegacy)
    if legacyScore >= modernScore + 3 {
        return (cleanLegacy, "legacy_command_override")
    }
    return (cleanModern, "speech_analyzer")
}

@discardableResult
private func setLoginItemEnabled(_ enabled: Bool) throws -> SMAppService.Status {
    let service = SMAppService.mainApp
    let plan = loginItemPlan(
        statusName: loginItemStatusName(service.status),
        enable: enabled
    )
    if plan == "register" {
        try service.register()
    } else if plan == "unregister" {
        try service.unregister()
    }
    return service.status
}

private enum VoiceSessionState {
    case idle
    case authorizing
    case recording
    case transcribing
}

private enum VoiceSessionError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case microphoneUnavailable
    case recognizerUnavailable
    case noSpeech
    case startFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off for Jarvis."
        case .speechDenied:
            return "Speech Recognition access is off for Jarvis."
        case .microphoneUnavailable:
            return "No usable microphone or audio input device is available."
        case .recognizerUnavailable:
            return "Speech recognition is currently unavailable on this Mac."
        case .noSpeech:
            return "No speech was recognized. Nothing was sent."
        case .startFailed(let detail):
            return "The microphone could not start: \(detail)"
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}

private final class PushToTalkRecorder: @unchecked Sendable {
    private(set) var state: VoiceSessionState = .idle
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingFile: AVAudioFile?
    private var recordingFileURL: URL?
    private var preserveCompletedAudio = false
    private var completedAudioURL: URL?
    private var recordingWriteError: Error?
    private var modernTranscriptionTask: Task<Void, Never>?
    private var modernStreamingTask: Task<Void, Never>?
    private var modernStreamingAppend: ((AVAudioPCMBuffer) -> Void)?
    private var modernStreamingFinish: (() -> Void)?
    private var modernStreamingWaitWorkItem: DispatchWorkItem?
    private var modernStreamingFinalTranscript = ""
    private var modernStreamingError: Error?
    private var modernStreamingFirstResultSeen = false
    private var highPassFilter: VoiceHighPassFilter?
    private var bestTranscript = ""
    private var recognitionError: Error?
    private var stopCompletion: ((Result<String, Error>) -> Void)?
    private var finalizationWorkItem: DispatchWorkItem?
    private let activityLock = NSLock()
    private var silenceHandler: (() -> Void)?
    private var recordingStartedAt: UInt64 = 0
    private var firstRecognizedAt: UInt64 = 0
    private var lastVoiceActivityAt: UInt64 = 0
    private var lastTranscriptUpdateAt: UInt64 = 0
    private var activityTranscript = ""
    private var hasRecognizedSpeech = false
    private var hasAcousticSpeech = false
    private var firstAcousticSpeechAt: UInt64 = 0
    private var lastAcousticSpeechAt: UInt64 = 0
    private var finalResultSeen = false
    private var silenceTriggered = false
    private var acousticSignalActive = false
    private var consecutiveVoiceBuffers = 0
    private var consecutiveSpeechDetectionBuffers = 0
    private var endpointReason = "manual"
    private var noiseFloorDB: Float = 0
    private var noiseFloorInitialized = false
    private var noiseFloorInherited = false
    private var audioBufferCount = 0
    private var peakAudioLevelDB: Float = -120
    private var peakPostCalibrationDB: Float = -120
    private var transcriptUpdateCount = 0

    func setPreserveCompletedAudio(_ enabled: Bool) {
        preserveCompletedAudio = enabled
        if !enabled, let completedAudioURL {
            try? FileManager.default.removeItem(at: completedAudioURL)
            self.completedAudioURL = nil
        }
    }

    func takeCompletedAudioURL() -> URL? {
        let value = completedAudioURL
        completedAudioURL = nil
        return value
    }

    func authorizeAndStart(
        initialNoiseFloorDB: Float? = nil,
        onSilenceDetected: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard state == .idle else {
            completion(.failure(VoiceSessionError.startFailed("Voice input is already active.")))
            return
        }
        if let completedAudioURL {
            try? FileManager.default.removeItem(at: completedAudioURL)
            self.completedAudioURL = nil
        }
        silenceHandler = onSilenceDetected
        state = .authorizing
        authorizeSpeech { [weak self] speechResult in
            guard let self, self.state == .authorizing else { return }
            switch speechResult {
            case .failure(let error):
                self.state = .idle
                self.silenceHandler = nil
                completion(.failure(error))
            case .success:
                self.authorizeMicrophone { [weak self] microphoneResult in
                    guard let self, self.state == .authorizing else { return }
                    switch microphoneResult {
                    case .failure(let error):
                        self.state = .idle
                        self.silenceHandler = nil
                        completion(.failure(error))
                    case .success:
                        do {
                            try self.startRecording(initialNoiseFloorDB: initialNoiseFloorDB)
                            completion(.success(()))
                        } catch {
                            self.resetSession()
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func authorizeSpeech(completion: @escaping (Result<Void, Error>) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(.success(()))
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized ? .success(()) : .failure(VoiceSessionError.speechDenied))
                }
            }
        default:
            completion(.failure(VoiceSessionError.speechDenied))
        }
    }

    private func authorizeMicrophone(completion: @escaping (Result<Void, Error>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(.success(()))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .success(()) : .failure(VoiceSessionError.microphoneDenied))
                }
            }
        default:
            completion(.failure(VoiceSessionError.microphoneDenied))
        }
    }

    @available(macOS 26.0, *)
    private func startModernStreamingRecognition(sourceFormat: AVAudioFormat) {
        let (capturedAudio, capturedAudioContinuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        modernStreamingFinalTranscript = ""
        modernStreamingError = nil
        modernStreamingFirstResultSeen = false
        modernStreamingAppend = { buffer in
            guard let copied = copySpeechBuffer(buffer) else { return }
            capturedAudioContinuation.yield(copied)
        }
        modernStreamingFinish = {
            capturedAudioContinuation.finish()
        }

        modernStreamingTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let base = try await configuredModernSpeechTranscriber()
                guard let locale = base.selectedLocales.first else {
                    throw VoiceSessionError.recognizerUnavailable
                }
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    preset: .progressiveTranscription
                )
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber],
                    considering: sourceFormat
                ), let converter = AVAudioConverter(
                    from: sourceFormat,
                    to: analyzerFormat
                ) else {
                    throw VoiceSessionError.startFailed(
                        "The on-device speech audio converter is unavailable."
                    )
                }

                let (analyzerInputs, analyzerInputContinuation) = AsyncStream.makeStream(
                    of: AnalyzerInput.self,
                    bufferingPolicy: .bufferingNewest(256)
                )
                let context = AnalysisContext()
                context.contextualStrings[.general] = voiceContextualPhrases
                let analyzer = SpeechAnalyzer(
                    modules: [transcriber],
                    options: SpeechAnalyzer.Options(
                        priority: .userInitiated,
                        modelRetention: .lingering
                    )
                )
                try await analyzer.setContext(context)

                let resultsTask = Task<String, Error> { [weak self] in
                    var finalTranscript = ""
                    var mostRecentTranscript = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        mostRecentTranscript = text
                        if result.isFinal {
                            if !finalTranscript.isEmpty { finalTranscript += " " }
                            finalTranscript += text
                        }
                        DispatchQueue.main.async {
                            self?.acceptModernStreamingTranscript(
                                text,
                                isFinal: result.isFinal
                            )
                        }
                    }
                    let completed = finalTranscript.isEmpty
                        ? mostRecentTranscript : finalTranscript
                    return completed.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                do {
                    try await analyzer.prepareToAnalyze(in: analyzerFormat)
                    try await analyzer.start(inputSequence: analyzerInputs)
                    logVoiceDiagnostic(
                        "modern_stream_ready rate=\(Int(analyzerFormat.sampleRate)) "
                        + "channels=\(analyzerFormat.channelCount)"
                    )
                    for await buffer in capturedAudio {
                        if Task.isCancelled { break }
                        if let converted = try convertSpeechBuffer(
                            buffer,
                            converter: converter,
                            outputFormat: analyzerFormat
                        ) {
                            analyzerInputContinuation.yield(
                                AnalyzerInput(buffer: converted)
                            )
                        }
                    }
                    analyzerInputContinuation.finish()
                    if Task.isCancelled {
                        resultsTask.cancel()
                        await analyzer.cancelAndFinishNow()
                        return
                    }
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    let transcript = try await resultsTask.value
                    DispatchQueue.main.async {
                        self?.modernStreamingDidFinish(
                            transcript: transcript,
                            error: nil
                        )
                    }
                } catch {
                    analyzerInputContinuation.finish()
                    resultsTask.cancel()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            } catch {
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.modernStreamingDidFinish(
                        transcript: "",
                        error: error
                    )
                }
            }
        }
    }

    private func acceptModernStreamingTranscript(_ transcript: String, isFinal: Bool) {
        guard state == .recording else { return }
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !modernStreamingFirstResultSeen {
            modernStreamingFirstResultSeen = true
            let elapsed = recordingStartedAt > 0
                ? Double(DispatchTime.now().uptimeNanoseconds - recordingStartedAt)
                    / 1_000_000_000.0
                : 0
            logVoiceDiagnostic(
                "modern_stream_first_result chars=\(cleaned.count) "
                + "latency=\(String(format: "%.2f", elapsed))s"
            )
        }
        let preferred = preferredTranscript(
            current: bestTranscript,
            candidate: cleaned,
            isFinal: isFinal
        )
        if preferred != bestTranscript {
            bestTranscript = preferred
            markRecognizedSpeech(preferred)
        }
    }

    private func modernStreamingDidFinish(transcript: String, error: Error?) {
        guard modernStreamingTask != nil else { return }
        modernStreamingTask = nil
        modernStreamingAppend = nil
        modernStreamingFinish = nil
        modernStreamingFinalTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        modernStreamingError = error
        if error == nil {
            let elapsed = recordingStartedAt > 0
                ? Double(DispatchTime.now().uptimeNanoseconds - recordingStartedAt)
                    / 1_000_000_000.0
                : 0
            logVoiceDiagnostic(
                "modern_stream_completed chars=\(modernStreamingFinalTranscript.count) "
                + "latency=\(String(format: "%.2f", elapsed))s"
            )
        }
        if let error {
            logVoiceDiagnostic("modern_stream_fallback " + errorDiagnostic(error))
        }
        if state == .transcribing {
            finishTranscription()
        }
    }

    private func finishModernStreamingInput() {
        modernStreamingAppend = nil
        modernStreamingFinish?()
        modernStreamingFinish = nil
    }

    private func cancelModernStreamingRecognition() {
        finishModernStreamingInput()
        modernStreamingTask?.cancel()
        modernStreamingTask = nil
    }

    private func startRecording(initialNoiseFloorDB: Float?) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw VoiceSessionError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceSessionError.microphoneUnavailable
        }
        highPassFilter = VoiceHighPassFilter(format: format)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.contextualStrings = voiceContextualPhrases
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-command-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        bestTranscript = ""
        recognitionError = nil
        recordingFile = file
        recordingFileURL = fileURL
        recordingWriteError = nil
        audioEngine = engine
        recognitionRequest = request
        state = .recording
        resetVoiceActivity(initialNoiseFloorDB: initialNoiseFloorDB)
        if #available(macOS 26.0, *) {
            startModernStreamingRecognition(sourceFormat: format)
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            do {
                try file.write(from: buffer)
            } catch {
                self.markRecordingWriteError(error)
            }
            self.modernStreamingAppend?(buffer)
            if let filteredLevel = self.highPassFilter?.filteredLevelDB(buffer) {
                self.analyzeVoiceActivity(levelDB: filteredLevel)
            }
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty {
                        let preferred = preferredTranscript(
                            current: self.bestTranscript,
                            candidate: transcript,
                            isFinal: result.isFinal
                        )
                        if preferred != self.bestTranscript {
                            self.bestTranscript = preferred
                            self.markRecognizedSpeech(preferred)
                        }
                    }
                    if result.isFinal {
                        self.markFinalRecognitionResult()
                    }
                    if result.isFinal, self.state == .transcribing {
                        self.finishTranscription()
                        return
                    }
                }
                if let error {
                    self.recognitionError = error
                    if self.state == .transcribing {
                        self.finishTranscription()
                    }
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            let baselineDescription = initialNoiseFloorDB.map {
                String(format: "%.1f", $0)
            } ?? "calibrating"
            logVoiceDiagnostic(
                "command_audio_started device=\(defaultInputDeviceName()) "
                + "rate=\(Int(format.sampleRate)) channels=\(format.channelCount) "
                + "baseline_db=\(baselineDescription)"
            )
        } catch {
            input.removeTap(onBus: 0)
            recognitionTask?.cancel()
            throw VoiceSessionError.startFailed(error.localizedDescription)
        }
    }

    private func resetVoiceActivity(initialNoiseFloorDB: Float?) {
        let now = DispatchTime.now().uptimeNanoseconds
        activityLock.lock()
        recordingStartedAt = now
        firstRecognizedAt = 0
        lastVoiceActivityAt = now
        lastTranscriptUpdateAt = now
        activityTranscript = ""
        hasRecognizedSpeech = false
        hasAcousticSpeech = false
        firstAcousticSpeechAt = 0
        lastAcousticSpeechAt = now
        finalResultSeen = false
        silenceTriggered = false
        acousticSignalActive = false
        consecutiveVoiceBuffers = 0
        consecutiveSpeechDetectionBuffers = 0
        endpointReason = "manual"
        noiseFloorDB = initialNoiseFloorDB ?? 0
        noiseFloorInitialized = initialNoiseFloorDB != nil
        noiseFloorInherited = initialNoiseFloorDB != nil
        audioBufferCount = 0
        peakAudioLevelDB = -120
        peakPostCalibrationDB = -120
        transcriptUpdateCount = 0
        activityLock.unlock()
    }

    private func markRecordingWriteError(_ error: Error) {
        activityLock.lock()
        if recordingWriteError == nil { recordingWriteError = error }
        activityLock.unlock()
    }

    private func markFinalRecognitionResult() {
        activityLock.lock()
        finalResultSeen = true
        activityLock.unlock()
    }

    private func markRecognizedSpeech(_ transcript: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        activityLock.lock()
        if !hasRecognizedSpeech {
            firstRecognizedAt = now
        }
        hasRecognizedSpeech = true
        lastVoiceActivityAt = now
        lastTranscriptUpdateAt = now
        activityTranscript = transcript
        transcriptUpdateCount += 1
        activityLock.unlock()
    }

    private func analyzeVoiceActivity(levelDB: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        let billion = 1_000_000_000.0
        var shouldStop = false
        var handler: (() -> Void)?

        activityLock.lock()
        audioBufferCount += 1
        peakAudioLevelDB = max(peakAudioLevelDB, levelDB)
        let elapsed = Double(now - recordingStartedAt) / billion
        if elapsed > voiceNoiseCalibrationSeconds {
            peakPostCalibrationDB = max(peakPostCalibrationDB, levelDB)
        }
        if !noiseFloorInitialized {
            noiseFloorDB = levelDB
            noiseFloorInitialized = true
        } else if elapsed <= voiceNoiseCalibrationSeconds && !noiseFloorInherited {
            noiseFloorDB = (noiseFloorDB * 0.90) + (levelDB * 0.10)
        }

        let detectionThreshold = max(
            noiseFloorDB + voiceAcousticDetectionMarginDB,
            -50.0
        )
        if elapsed > voiceNoiseCalibrationSeconds && levelDB >= detectionThreshold {
            consecutiveSpeechDetectionBuffers += 1
            if consecutiveSpeechDetectionBuffers >= voiceMinimumDetectionBuffers {
                if !hasAcousticSpeech {
                    hasAcousticSpeech = true
                    firstAcousticSpeechAt = now
                }
                lastAcousticSpeechAt = now
            }
        } else {
            consecutiveSpeechDetectionBuffers = 0
        }

        let signalMargin = acousticSignalActive
            ? voiceSignalReleaseMarginDB : voiceSignalMarginDB
        let threshold = max(noiseFloorDB + signalMargin, -48.0)
        let voiceLike = levelDB >= threshold
        if voiceLike {
            acousticSignalActive = true
            consecutiveVoiceBuffers += 1
            if consecutiveVoiceBuffers >= 2 {
                lastVoiceActivityAt = now
            }
        } else {
            acousticSignalActive = false
            consecutiveVoiceBuffers = 0
            if elapsed > voiceNoiseCalibrationSeconds,
               levelDB > noiseFloorDB,
               levelDB < noiseFloorDB + 3.0 {
                noiseFloorDB = (noiseFloorDB * 0.995) + (levelDB * 0.005)
            }
        }

        let quietFor = Double(now - lastVoiceActivityAt) / billion
        let transcriptQuietFor = Double(now - lastTranscriptUpdateAt) / billion
        let recognizedFor = firstRecognizedAt > 0
            ? Double(now - firstRecognizedAt) / billion : 0
        let acousticSpeechFor = firstAcousticSpeechAt > 0
            ? Double(now - firstAcousticSpeechAt) / billion : 0
        let acousticFallbackQuietFor = Double(now - lastAcousticSpeechAt) / billion
        let recognizedEndpoint = shouldFinalizeRecognizedCommand(
            transcript: activityTranscript,
            acousticQuietFor: hasAcousticSpeech ? acousticFallbackQuietFor : quietFor,
            transcriptQuietFor: transcriptQuietFor,
            recognizedFor: recognizedFor
        )
        let reportedFinalEndpoint = shouldFinalizeReportedFinal(
            transcript: activityTranscript,
            isFinal: finalResultSeen,
            acousticQuietFor: quietFor,
            transcriptQuietFor: transcriptQuietFor
        )
        let acousticEndpoint = !hasRecognizedSpeech && shouldFinalizeAcousticFallback(
            heardAcousticSpeech: hasAcousticSpeech,
            acousticQuietFor: acousticFallbackQuietFor,
            acousticSpeechFor: acousticSpeechFor
        )
        let noSpeechEndpoint = !hasRecognizedSpeech && !hasAcousticSpeech
            && elapsed >= voiceNoSpeechTimeoutSeconds
        let unrecognizedAudioEndpoint = shouldFinalizeUnrecognizedAudio(
            hasRecognizedSpeech: hasRecognizedSpeech,
            elapsed: elapsed
        )
        let maximumEndpoint = elapsed >= voiceMaximumCommandSeconds
        if !silenceTriggered,
           (reportedFinalEndpoint || recognizedEndpoint || acousticEndpoint
                || noSpeechEndpoint || unrecognizedAudioEndpoint || maximumEndpoint) {
            silenceTriggered = true
            shouldStop = true
            handler = silenceHandler
            if reportedFinalEndpoint {
                endpointReason = "reported_final_silence"
            } else if recognizedEndpoint {
                endpointReason = "recognized_silence"
            } else if acousticEndpoint {
                endpointReason = "acoustic_silence"
            } else if noSpeechEndpoint {
                endpointReason = "no_speech_timeout"
            } else if unrecognizedAudioEndpoint {
                endpointReason = "unrecognized_audio_timeout"
            } else {
                endpointReason = "maximum_duration"
            }
        }
        activityLock.unlock()

        if shouldStop {
            DispatchQueue.main.async { handler?() }
        }
    }

    func stop(completion: @escaping (Result<String, Error>) -> Void) {
        guard state == .recording, let engine = audioEngine else {
            completion(.failure(VoiceSessionError.startFailed("Voice input is not recording.")))
            return
        }
        state = .transcribing
        activityLock.lock()
        silenceTriggered = true
        let resultAlreadyFinal = finalResultSeen
        let stopReason = endpointReason
        let stopDuration = recordingStartedAt > 0
            ? Double(DispatchTime.now().uptimeNanoseconds - recordingStartedAt)
                / 1_000_000_000.0
            : 0
        activityLock.unlock()
        logVoiceDiagnostic(
            "command_audio_stopped endpoint=\(stopReason) "
            + "duration=\(String(format: "%.2f", stopDuration))s"
        )
        stopCompletion = completion
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        finishModernStreamingInput()
        recordingFile = nil
        recognitionRequest?.endAudio()

        if resultAlreadyFinal {
            finishTranscription()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.finishTranscription()
        }
        finalizationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + voiceFinalizationTimeoutSeconds,
            execute: work
        )
    }

    func cancel() {
        resetSession()
    }

    private func finishTranscription() {
        guard state == .transcribing, modernTranscriptionTask == nil else { return }
        if modernStreamingTask != nil {
            if modernStreamingWaitWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .transcribing else { return }
                    if self.modernStreamingTask != nil {
                        logVoiceDiagnostic("modern_stream_finalize_timeout")
                        self.cancelModernStreamingRecognition()
                    }
                    self.modernStreamingWaitWorkItem = nil
                    self.finishTranscription()
                }
                modernStreamingWaitWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + voiceModernStreamingFinalizationTimeoutSeconds,
                    execute: work
                )
            }
            return
        }
        modernStreamingWaitWorkItem?.cancel()
        modernStreamingWaitWorkItem = nil
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        let legacyTranscript = bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyError = recognitionError
        let streamingTranscript = modernStreamingFinalTranscript
        let streamingError = modernStreamingError
        let fileURL = recordingFileURL
        activityLock.lock()
        let buffers = audioBufferCount
        let peak = peakAudioLevelDB
        let updates = transcriptUpdateCount
        let floor = noiseFloorDB
        let fileError = recordingWriteError
        let duration = recordingStartedAt > 0
            ? Double(DispatchTime.now().uptimeNanoseconds - recordingStartedAt)
                / 1_000_000_000.0
            : 0
        let wasFinal = finalResultSeen
        activityLock.unlock()

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        recordingFile = nil

        if !streamingTranscript.isEmpty {
            completeTranscription(
                modernTranscript: streamingTranscript,
                modernError: nil,
                legacyTranscript: legacyTranscript,
                legacyError: legacyError,
                fileURL: fileURL,
                buffers: buffers,
                peak: peak,
                floor: floor,
                updates: updates,
                duration: duration,
                legacyWasFinal: wasFinal
            )
            return
        }

        if #available(macOS 26.0, *), let fileURL, fileError == nil {
            modernTranscriptionTask = Task { [weak self] in
                do {
                    let transcript = try await transcribeWithModernSpeech(fileURL: fileURL)
                    DispatchQueue.main.async {
                        self?.completeTranscription(
                            modernTranscript: transcript,
                            modernError: nil,
                            legacyTranscript: legacyTranscript,
                            legacyError: legacyError,
                            fileURL: fileURL,
                            buffers: buffers,
                            peak: peak,
                            floor: floor,
                            updates: updates,
                            duration: duration,
                            legacyWasFinal: wasFinal
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.completeTranscription(
                            modernTranscript: "",
                            modernError: error,
                            legacyTranscript: legacyTranscript,
                            legacyError: legacyError,
                            fileURL: fileURL,
                            buffers: buffers,
                            peak: peak,
                            floor: floor,
                            updates: updates,
                            duration: duration,
                            legacyWasFinal: wasFinal
                        )
                    }
                }
            }
            return
        }
        if let fileError {
            logVoiceDiagnostic("command_audio_file_error " + errorDiagnostic(fileError))
        }
        completeTranscription(
            modernTranscript: "",
            modernError: streamingError ?? fileError,
            legacyTranscript: legacyTranscript,
            legacyError: legacyError,
            fileURL: fileURL,
            buffers: buffers,
            peak: peak,
            floor: floor,
            updates: updates,
            duration: duration,
            legacyWasFinal: wasFinal
        )
    }

    private func completeTranscription(
        modernTranscript: String,
        modernError: Error?,
        legacyTranscript: String,
        legacyError: Error?,
        fileURL: URL?,
        buffers: Int,
        peak: Float,
        floor: Float,
        updates: Int,
        duration: Double,
        legacyWasFinal: Bool,
        allowWhisperFallback: Bool = true,
        engineOverride: String? = nil
    ) {
        guard state == .transcribing else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            return
        }
        modernTranscriptionTask = nil
        let cleanedModern = modernTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = preferredRecognitionCandidate(
            modern: cleanedModern,
            legacy: legacyTranscript
        )
        let transcript = normalizeRecognizedTranscript(candidate.transcript)
        if transcript.isEmpty,
           allowWhisperFallback,
           let fileURL,
           LocalWhisperFallback.isAvailable {
            logVoiceDiagnostic("whisper_fallback_started")
            modernTranscriptionTask = Task { [weak self] in
                let fallbackResult = await Task.detached(priority: .userInitiated) {
                    Result { try LocalWhisperFallback.transcribe(fileURL: fileURL) }
                }.value
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch fallbackResult {
                    case .success(let fallbackTranscript):
                        logVoiceDiagnostic("whisper_fallback_completed")
                        self.completeTranscription(
                            modernTranscript: fallbackTranscript,
                            modernError: nil,
                            legacyTranscript: "",
                            legacyError: legacyError,
                            fileURL: fileURL,
                            buffers: buffers,
                            peak: peak,
                            floor: floor,
                            updates: updates,
                            duration: duration,
                            legacyWasFinal: legacyWasFinal,
                            allowWhisperFallback: false,
                            engineOverride: "whisper_large_v3_turbo"
                        )
                    case .failure(let fallbackError):
                        logVoiceDiagnostic(
                            "whisper_fallback_failed " + errorDiagnostic(fallbackError)
                        )
                        self.completeTranscription(
                            modernTranscript: "",
                            modernError: fallbackError,
                            legacyTranscript: "",
                            legacyError: legacyError,
                            fileURL: fileURL,
                            buffers: buffers,
                            peak: peak,
                            floor: floor,
                            updates: updates,
                            duration: duration,
                            legacyWasFinal: legacyWasFinal,
                            allowWhisperFallback: false
                        )
                    }
                }
            }
            return
        }
        let selectedEngine = engineOverride ?? candidate.engine
        if candidate.engine == "legacy_command_override" {
            logVoiceDiagnostic("recognition_candidate selected=legacy_command_override")
        }
        activityLock.lock()
        let completedEndpointReason = endpointReason
        let completedPostCalibrationPeak = peakPostCalibrationDB
        let completedHadAcousticSpeech = hasAcousticSpeech
        let completedHadRecognizedSpeech = hasRecognizedSpeech
        activityLock.unlock()
        let completion = stopCompletion
        if !transcript.isEmpty, preserveCompletedAudio, let fileURL {
            recordingFileURL = nil
            completedAudioURL = fileURL
        }
        resetSession()
        if !transcript.isEmpty {
            logVoiceDiagnostic(
                "command_transcript chars=\(transcript.count) "
                + "words=\(transcriptWords(transcript).count) updates=\(updates) "
                + "duration=\(String(format: "%.2f", duration))s "
                + "engine=\(selectedEngine) legacy_final=\(legacyWasFinal) "
                + "endpoint=\(completedEndpointReason) buffers=\(buffers) "
                + "peak_db=\(String(format: "%.1f", peak)) "
                + "post_peak_db=\(String(format: "%.1f", completedPostCalibrationPeak)) "
                + "floor_db=\(String(format: "%.1f", floor))"
            )
            if let modernError {
                logVoiceDiagnostic("modern_speech_fallback " + errorDiagnostic(modernError))
            }
            completion?(.success(transcript))
        } else if let error = modernError ?? legacyError {
            logVoiceDiagnostic(
                "command_transcription_error updates=\(updates) buffers=\(buffers) "
                + "endpoint=\(completedEndpointReason) "
                + "acoustic=\(completedHadAcousticSpeech) "
                + "recognized=\(completedHadRecognizedSpeech) "
                + "peak_db=\(String(format: "%.1f", peak)) "
                + "post_peak_db=\(String(format: "%.1f", completedPostCalibrationPeak)) "
                + "floor_db=\(String(format: "%.1f", floor)) "
                + errorDiagnostic(error)
            )
            completion?(.failure(VoiceSessionError.transcriptionFailed(error.localizedDescription)))
        } else {
            logVoiceDiagnostic(
                "command_no_speech updates=\(updates) buffers=\(buffers) "
                + "endpoint=\(completedEndpointReason) "
                + "acoustic=\(completedHadAcousticSpeech) "
                + "recognized=\(completedHadRecognizedSpeech) "
                + "peak_db=\(String(format: "%.1f", peak)) "
                + "post_peak_db=\(String(format: "%.1f", completedPostCalibrationPeak)) "
                + "floor_db=\(String(format: "%.1f", floor))"
            )
            completion?(.failure(VoiceSessionError.noSpeech))
        }
    }

    private func resetSession() {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        modernStreamingWaitWorkItem?.cancel()
        modernStreamingWaitWorkItem = nil
        modernTranscriptionTask?.cancel()
        modernTranscriptionTask = nil
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        cancelModernStreamingRecognition()
        modernStreamingFinalTranscript = ""
        modernStreamingError = nil
        modernStreamingFirstResultSeen = false
        highPassFilter = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        recordingFile = nil
        if let recordingFileURL {
            try? FileManager.default.removeItem(at: recordingFileURL)
        }
        recordingFileURL = nil
        recordingWriteError = nil
        bestTranscript = ""
        recognitionError = nil
        stopCompletion = nil
        silenceHandler = nil
        state = .idle
    }
}

private struct OwnerVoiceMatch {
    let accepted: Bool
    let reason: String
    let similarity: Double
    let threshold: Double
    let referenceMatches: Int
    let pitchMatch: Bool
    let matchTier: String
}

private let ownerVoiceMaximumEffectiveThreshold = 0.68
private let ownerVoiceReferenceTolerance = 0.10
private let ownerVoiceRequiredReferenceMatches = 2
private let ownerVoiceDistantThreshold = 0.58
private let ownerVoiceDistantReferenceTolerance = 0.10
private let ownerVoiceDistantRequiredReferenceMatches = 2
private let ownerVoiceMinimumReliablePitchHz = 65.0
private let ownerVoiceMaximumReliablePitchHz = 330.0

private struct OwnerVoiceProfile {
    let centroid: [Float]
    let references: [[Float]]
    let threshold: Double
    let pitchCenterHz: Double
    let pitchToleranceLog: Double

    init?(data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              payload["version"] as? Int == 1,
              let rawCentroid = payload["centroid"] as? [NSNumber],
              rawCentroid.count == 256,
              let rawReferences = payload["references"] as? [[NSNumber]],
              rawReferences.count >= 5,
              let threshold = (payload["similarity_threshold"] as? NSNumber)?.doubleValue
        else { return nil }
        centroid = rawCentroid.map(\.floatValue)
        references = rawReferences.compactMap { values in
            values.count == 256 ? values.map(\.floatValue) : nil
        }
        guard references.count >= 5 else { return nil }
        self.threshold = threshold
        pitchCenterHz = (
            payload["pitch_center_hz"] as? NSNumber
        )?.doubleValue ?? 0
        pitchToleranceLog = (
            payload["pitch_tolerance_log"] as? NSNumber
        )?.doubleValue ?? 0.18
    }

    private func similarity(_ left: [Float], _ right: [Float]) -> Double {
        guard left.count == right.count else { return -1 }
        var value = 0.0
        for index in left.indices {
            value += Double(left[index] * right[index])
        }
        return value
    }

    func match(voiceprint: [String: Any]) -> OwnerVoiceMatch {
        guard let rawEmbedding = voiceprint["embedding"] as? [NSNumber],
              rawEmbedding.count == 256 else {
            return OwnerVoiceMatch(
                accepted: false,
                reason: "invalid_embedding",
                similarity: 0,
                threshold: min(threshold, ownerVoiceMaximumEffectiveThreshold),
                referenceMatches: 0,
                pitchMatch: false,
                matchTier: "none"
            )
        }
        let embedding = rawEmbedding.map(\.floatValue)
        let centroidScore = similarity(embedding, centroid)
        let effectiveThreshold = min(threshold, ownerVoiceMaximumEffectiveThreshold)
        let strictReferenceFloor = effectiveThreshold - ownerVoiceReferenceTolerance
        let strictReferenceMatches = references.reduce(0) {
            $0 + (similarity(embedding, $1) >= strictReferenceFloor ? 1 : 0)
        }
        let requiredReferences = min(
            ownerVoiceRequiredReferenceMatches,
            references.count
        )
        let strongSpeakerMatch = centroidScore >= effectiveThreshold
            && strictReferenceMatches >= requiredReferences
        let distantThreshold = min(threshold, ownerVoiceDistantThreshold)
        let distantReferenceFloor = distantThreshold
            - ownerVoiceDistantReferenceTolerance
        let distantReferenceMatches = references.reduce(0) {
            $0 + (similarity(embedding, $1) >= distantReferenceFloor ? 1 : 0)
        }
        let distantRequiredReferences = min(
            ownerVoiceDistantRequiredReferenceMatches,
            references.count
        )
        let distantSpeakerMatch = centroidScore >= distantThreshold
            && distantReferenceMatches >= distantRequiredReferences
        let speakerMatch = strongSpeakerMatch || distantSpeakerMatch
        let matchTier = strongSpeakerMatch ? "strong" : (speakerMatch ? "distant" : "none")
        let pitch = (voiceprint["pitch_hz"] as? NSNumber)?.doubleValue ?? 0
        let pitchMatch: Bool
        let pitchCheckReliable = ownerVoiceMinimumReliablePitchHz...ownerVoiceMaximumReliablePitchHz
        if pitchCheckReliable.contains(pitchCenterHz),
           pitchCheckReliable.contains(pitch) {
            pitchMatch = abs(log(pitch / pitchCenterHz)) <= pitchToleranceLog
        } else {
            pitchMatch = true
        }
        return OwnerVoiceMatch(
            accepted: speakerMatch && pitchMatch,
            reason: speakerMatch
                ? (pitchMatch ? "owner_regular_voice" : "voice_style_mismatch")
                : "speaker_mismatch",
            similarity: centroidScore,
            threshold: strongSpeakerMatch ? effectiveThreshold : distantThreshold,
            referenceMatches: strongSpeakerMatch
                ? strictReferenceMatches : distantReferenceMatches,
            pitchMatch: pitchMatch,
            matchTier: matchTier
        )
    }
}

private final class OwnerVoiceRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.pbbuilds.jarvis.owner-voice",
        qos: .userInitiated
    )
    private var model: JarvisVoiceprintModel?
    private var profile: OwnerVoiceProfile?

    private var modelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Jarvis/Models/OwnerVoice/wespeaker_v2.mlmodelc"
            )
    }

    private func loadProfile() -> OwnerVoiceProfile? {
        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jarvis/Data/bin/jarvis-keychain")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "get",
            "dev.pbbuilds.jarvis.owner-voice-profile",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return OwnerVoiceProfile(data: data)
        } catch {
            return nil
        }
    }

    private func prepareIfNeeded() throws {
        if profile == nil {
            profile = loadProfile()
        }
        guard profile != nil else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 135,
                userInfo: [NSLocalizedDescriptionKey: "The owner voice profile is unavailable."]
            )
        }
        if model == nil {
            model = try JarvisVoiceprintModel(modelURL: modelURL)
        }
    }

    func preload() {
        queue.async {
            let started = Date()
            do {
                try self.prepareIfNeeded()
                logVoiceDiagnostic(
                    "owner_voice_model_ready load_ms=\(Int(Date().timeIntervalSince(started) * 1_000))"
                )
            } catch {
                logVoiceDiagnostic(
                    "owner_voice_model_unavailable " + errorDiagnostic(error)
                )
            }
        }
    }

    func reload() {
        queue.async {
            self.profile = nil
            do {
                try self.prepareIfNeeded()
                logVoiceDiagnostic("owner_voice_profile_reloaded")
            } catch {
                logVoiceDiagnostic(
                    "owner_voice_profile_reload_failed " + errorDiagnostic(error)
                )
            }
        }
    }

    func unload() {
        queue.async {
            self.model = nil
            self.profile = nil
            logVoiceDiagnostic("owner_voice_model_unloaded")
        }
    }

    func verify(
        audioURL: URL,
        completion: @escaping (Result<OwnerVoiceMatch, Error>) -> Void
    ) {
        queue.async {
            let result: Result<OwnerVoiceMatch, Error>
            do {
                try self.prepareIfNeeded()
                guard let model = self.model, let profile = self.profile else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 136,
                        userInfo: [NSLocalizedDescriptionKey: "Owner voice is not ready."]
                    )
                }
                let voiceprint = try model.extract(audioURL: audioURL)
                result = .success(profile.match(voiceprint: voiceprint))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class WakeVoiceRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capacity = 0
    private var writeIndex = 0
    private var storedCount = 0
    private var sampleRate = 0.0

    func reset(format: AVAudioFormat, seconds: Double = 9.0) {
        let rate = format.sampleRate
        let count = max(1, Int(rate * seconds))
        lock.lock()
        sampleRate = rate
        capacity = count
        samples = [Float](repeating: 0, count: count)
        writeIndex = 0
        storedCount = 0
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = max(1, Int(buffer.format.channelCount))
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        lock.lock()
        guard capacity > 0 else {
            lock.unlock()
            return
        }
        for frame in 0..<frameCount {
            var mono: Float = 0
            for channel in 0..<channelCount {
                mono += channels[channel][frame]
            }
            mono /= Float(channelCount)
            samples[writeIndex] = mono
            writeIndex = (writeIndex + 1) % capacity
            storedCount = min(capacity, storedCount + 1)
        }
        lock.unlock()
    }

    func exportRecentSample() -> URL? {
        lock.lock()
        let count = storedCount
        let rate = sampleRate
        let start = (writeIndex - count + capacity) % max(1, capacity)
        var snapshot = [Float](repeating: 0, count: count)
        if count > 0 {
            for index in 0..<count {
                snapshot[index] = samples[(start + index) % capacity]
            }
        }
        lock.unlock()
        guard count > Int(rate * 0.65), rate > 0 else { return nil }

        do {
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            ), let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let destinationChannel = source.floatChannelData?[0] else {
                return nil
            }
            source.frameLength = AVAudioFrameCount(count)
            snapshot.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                memcpy(destinationChannel, base, count * MemoryLayout<Float>.size)
            }
            guard let converter = AVAudioConverter(
                from: sourceFormat,
                to: targetFormat
            ) else { return nil }
            let outputCapacity = AVAudioFrameCount(
                max(1, ceil(Double(count) * 16_000.0 / rate) + 256)
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else { return nil }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            guard status != .error, output.frameLength > 0 else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("jarvis-owner-voice-\(UUID().uuidString).wav")
            let file = try AVAudioFile(
                forWriting: url,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: output)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            logVoiceDiagnostic("owner_voice_sample_export_failed " + errorDiagnostic(error))
            return nil
        }
    }
}

private final class WakeWordListener: @unchecked Sendable {
    private(set) var isListening = false
    private var desiredRunning = false
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var highPassFilter: VoiceHighPassFilter?
    private var restartWorkItem: DispatchWorkItem?
    private var wakeFinalizationWorkItem: DispatchWorkItem?
    private var detectionHandler: ((URL?) -> Void)?
    private var wakeWordHeardHandler: (() -> Void)?
    private var siriWakeHandler: (() -> Void)?
    private var commandHandler: ((String, URL?) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var generation = 0
    private var wakeWordSeen = false
    private var latestInlineCommand = ""
    private var finalizingWakeCommand = false
    private let activityLock = NSLock()
    private var sessionStartedAt: UInt64 = 0
    private var firstWakeCommandAt: UInt64 = 0
    private var lastVoiceActivityAt: UInt64 = 0
    private var lastWakeTranscriptUpdateAt: UInt64 = 0
    private var wakeActivityTranscript = ""
    private var noiseFloorDB: Float = 0
    private var noiseFloorInitialized = false
    private var acousticSignalActive = false
    private var consecutiveVoiceBuffers = 0
    private var audioBufferCount = 0
    private var peakAudioLevelDB: Float = -120
    private var transcriptUpdateCount = 0
    private var lastAudioBufferAt: UInt64 = 0
    private var restartAttempt = 0
    private let voiceRing = WakeVoiceRingBuffer()

    func calibratedNoiseFloorDB() -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        activityLock.lock()
        let elapsed = sessionStartedAt > 0
            ? Double(now - sessionStartedAt) / 1_000_000_000.0 : 0
        let floor = noiseFloorInitialized && elapsed >= voiceNoiseCalibrationSeconds
            ? noiseFloorDB : nil
        activityLock.unlock()
        return floor
    }

    func start(
        onDetected: @escaping (URL?) -> Void,
        onWakeWordHeard: @escaping () -> Void,
        onSiriWakeWord: @escaping () -> Void,
        onCommandDetected: @escaping (String, URL?) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        guard !desiredRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw VoiceSessionError.speechDenied
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw VoiceSessionError.microphoneDenied
        }
        detectionHandler = onDetected
        wakeWordHeardHandler = onWakeWordHeard
        siriWakeHandler = onSiriWakeWord
        commandHandler = onCommandDetected
        errorHandler = onError
        desiredRunning = true
        do {
            try startSession()
        } catch {
            desiredRunning = false
            teardownSession()
            throw error
        }
    }

    func stop() {
        desiredRunning = false
        restartAttempt = 0
        restartWorkItem?.cancel()
        restartWorkItem = nil
        wakeFinalizationWorkItem?.cancel()
        wakeFinalizationWorkItem = nil
        teardownSession()
    }

    private func startSession() throws {
        guard desiredRunning, !isListening else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw VoiceSessionError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceSessionError.microphoneUnavailable
        }
        highPassFilter = VoiceHighPassFilter(format: format)
        voiceRing.reset(format: format)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = voiceContextualPhrases

        generation += 1
        let sessionGeneration = generation
        wakeWordSeen = false
        latestInlineCommand = ""
        finalizingWakeCommand = false
        resetVoiceActivity()
        audioEngine = engine
        recognitionRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            self.voiceRing.append(buffer)
            if let filteredLevel = self.highPassFilter?.filteredLevelDB(buffer) {
                self.analyzeWakeVoiceActivity(
                    levelDB: filteredLevel,
                    generation: sessionGeneration
                )
            }
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self,
                      self.desiredRunning,
                      self.generation == sessionGeneration else { return }
                if let result,
                   isSiriWakeTranscript(result.bestTranscription.formattedString) {
                    let handler = self.siriWakeHandler
                    self.desiredRunning = false
                    self.teardownSession()
                    logVoiceDiagnostic("siri_wake_handoff")
                    handler?()
                    return
                }
                if let result,
                   let command = wakeCommandAfterWakeWord(
                       result.bestTranscription.formattedString
                   ) {
                    let firstWakeRecognition = !self.wakeWordSeen
                    self.wakeWordSeen = true
                    if firstWakeRecognition {
                        self.wakeWordHeardHandler?()
                    }
                    if !command.isEmpty {
                        self.latestInlineCommand = preferredTranscript(
                            current: self.latestInlineCommand,
                            candidate: command,
                            isFinal: result.isFinal
                        )
                    }
                    self.markWakeTranscriptUpdate(self.latestInlineCommand)
                    logVoiceDiagnostic(
                        "wake_partial tail_chars=\(command.count) final=\(result.isFinal)"
                    )
                    if result.isFinal {
                        self.finishWakeDetection(command: self.latestInlineCommand)
                    } else if !command.isEmpty, !self.finalizingWakeCommand {
                        self.scheduleWakeFinalization(
                            after: commandEndSilenceSeconds(self.latestInlineCommand)
                        )
                    } else if !self.finalizingWakeCommand {
                        self.scheduleWakeFinalization(after: voiceWakeOnlyGraceSeconds)
                    }
                    return
                }
                if let error {
                    logVoiceDiagnostic("wake_recognition_restart " + errorDiagnostic(error))
                }
                if error != nil || result?.isFinal == true {
                    if self.wakeWordSeen {
                        self.finishWakeDetection(command: self.latestInlineCommand)
                    } else {
                        self.scheduleRestart()
                    }
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            restartAttempt = 0
            logVoiceDiagnostic(
                "wake_audio_started device=\(defaultInputDeviceName()) "
                + "rate=\(Int(format.sampleRate)) channels=\(format.channelCount)"
            )
        } catch {
            input.removeTap(onBus: 0)
            recognitionTask?.cancel()
            audioEngine = nil
            recognitionRequest = nil
            recognitionTask = nil
            throw VoiceSessionError.startFailed(error.localizedDescription)
        }
    }

    private func resetVoiceActivity() {
        let now = DispatchTime.now().uptimeNanoseconds
        activityLock.lock()
        sessionStartedAt = now
        firstWakeCommandAt = 0
        lastVoiceActivityAt = now
        lastWakeTranscriptUpdateAt = now
        wakeActivityTranscript = ""
        noiseFloorDB = 0
        noiseFloorInitialized = false
        acousticSignalActive = false
        consecutiveVoiceBuffers = 0
        audioBufferCount = 0
        peakAudioLevelDB = -120
        transcriptUpdateCount = 0
        lastAudioBufferAt = now
        activityLock.unlock()
    }

    private func markWakeTranscriptUpdate(_ transcript: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        activityLock.lock()
        if firstWakeCommandAt == 0, !transcript.isEmpty {
            firstWakeCommandAt = now
        }
        lastWakeTranscriptUpdateAt = now
        wakeActivityTranscript = transcript
        transcriptUpdateCount += 1
        activityLock.unlock()
    }

    private func analyzeWakeVoiceActivity(
        levelDB: Float,
        generation sessionGeneration: Int
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let billion = 1_000_000_000.0
        var shouldFinalize = false

        activityLock.lock()
        audioBufferCount += 1
        lastAudioBufferAt = now
        peakAudioLevelDB = max(peakAudioLevelDB, levelDB)
        let elapsed = Double(now - sessionStartedAt) / billion
        if !noiseFloorInitialized {
            noiseFloorDB = levelDB
            noiseFloorInitialized = true
        } else if elapsed <= voiceNoiseCalibrationSeconds {
            noiseFloorDB = (noiseFloorDB * 0.90) + (levelDB * 0.10)
        }

        let signalMargin = acousticSignalActive
            ? voiceSignalReleaseMarginDB : voiceSignalMarginDB
        let threshold = max(noiseFloorDB + signalMargin, -48.0)
        if levelDB >= threshold {
            acousticSignalActive = true
            consecutiveVoiceBuffers += 1
            if consecutiveVoiceBuffers >= 2 {
                lastVoiceActivityAt = now
            }
        } else {
            acousticSignalActive = false
            consecutiveVoiceBuffers = 0
            if elapsed > voiceNoiseCalibrationSeconds,
               levelDB > noiseFloorDB,
               levelDB < noiseFloorDB + 3.0 {
                noiseFloorDB = (noiseFloorDB * 0.995) + (levelDB * 0.005)
            }
        }

        let quietFor = Double(now - lastVoiceActivityAt) / billion
        let transcriptQuietFor = Double(now - lastWakeTranscriptUpdateAt) / billion
        let recognizedFor = firstWakeCommandAt > 0
            ? Double(now - firstWakeCommandAt) / billion : 0
        shouldFinalize = shouldFinalizeRecognizedCommand(
            transcript: wakeActivityTranscript,
            acousticQuietFor: quietFor,
            transcriptQuietFor: transcriptQuietFor,
            recognizedFor: recognizedFor
        )
        activityLock.unlock()

        guard shouldFinalize else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.desiredRunning,
                  self.generation == sessionGeneration,
                  self.wakeWordSeen,
                  !self.finalizingWakeCommand else { return }
            self.beginWakeFinalization()
        }
    }

    private func beginWakeFinalization() {
        guard desiredRunning, wakeWordSeen, !finalizingWakeCommand else { return }
        finalizingWakeCommand = true
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()

        let sessionGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.desiredRunning,
                  self.generation == sessionGeneration else { return }
            self.finishWakeDetection(command: self.latestInlineCommand)
        }
        wakeFinalizationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func wakeCommandReadyToFinalize() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let billion = 1_000_000_000.0
        activityLock.lock()
        let transcript = wakeActivityTranscript
        let quietFor = Double(now - lastVoiceActivityAt) / billion
        let transcriptQuietFor = Double(now - lastWakeTranscriptUpdateAt) / billion
        let recognizedFor = firstWakeCommandAt > 0
            ? Double(now - firstWakeCommandAt) / billion : 0
        activityLock.unlock()
        return shouldFinalizeRecognizedCommand(
            transcript: transcript,
            acousticQuietFor: quietFor,
            transcriptQuietFor: transcriptQuietFor,
            recognizedFor: recognizedFor
        )
    }

    private func scheduleWakeFinalization(after seconds: Double) {
        wakeFinalizationWorkItem?.cancel()
        let sessionGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.desiredRunning,
                  self.generation == sessionGeneration,
                  !self.finalizingWakeCommand else { return }
            if self.latestInlineCommand.isEmpty || self.wakeCommandReadyToFinalize() {
                self.beginWakeFinalization()
            } else {
                self.scheduleWakeFinalization(after: 0.20)
            }
        }
        wakeFinalizationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + seconds,
            execute: work
        )
    }

    private func finishWakeDetection(command: String) {
        let wakeHandler = detectionHandler
        let inlineHandler = commandHandler
        let ownerVoiceSample = voiceRing.exportRecentSample()
        desiredRunning = false
        wakeFinalizationWorkItem?.cancel()
        wakeFinalizationWorkItem = nil
        activityLock.lock()
        let buffers = audioBufferCount
        let peak = peakAudioLevelDB
        let floor = noiseFloorDB
        let updates = transcriptUpdateCount
        activityLock.unlock()
        teardownSession()
        if command.isEmpty {
            logVoiceDiagnostic(
                "wake_standalone_command_session updates=\(updates) buffers=\(buffers) "
                + "peak_db=\(String(format: "%.1f", peak)) "
                + "floor_db=\(String(format: "%.1f", floor))"
            )
            wakeHandler?(ownerVoiceSample)
        } else {
            logVoiceDiagnostic(
                "wake_inline_command chars=\(command.count) "
                + "words=\(transcriptWords(command).count) updates=\(updates) "
                + "buffers=\(buffers) peak_db=\(String(format: "%.1f", peak))"
            )
            inlineHandler?(command, ownerVoiceSample)
        }
    }

    func maintainHealth() {
        guard desiredRunning else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let billion = 1_000_000_000.0
        activityLock.lock()
        let audioQuietFor = lastAudioBufferAt > 0
            ? Double(now - lastAudioBufferAt) / billion : .infinity
        let sessionAge = sessionStartedAt > 0
            ? Double(now - sessionStartedAt) / billion : .infinity
        activityLock.unlock()

        let reason: String?
        if !isListening {
            reason = "not_listening"
        } else if audioEngine?.isRunning != true {
            reason = "engine_stopped"
        } else if audioQuietFor >= wakeAudioStallTimeoutSeconds {
            reason = "audio_stalled"
        } else if sessionAge >= wakeSessionRefreshSeconds {
            reason = "scheduled_refresh"
        } else {
            reason = nil
        }
        guard let reason else { return }
        logVoiceDiagnostic("wake_health_restart reason=\(reason)")
        scheduleRestart(after: 0.15)
    }

    func refreshAudioRoute() {
        guard desiredRunning else { return }
        logVoiceDiagnostic("wake_audio_route_refresh")
        scheduleRestart(after: 0.20)
    }

    private func scheduleRestart(after requestedDelay: Double? = nil) {
        wakeFinalizationWorkItem?.cancel()
        wakeFinalizationWorkItem = nil
        teardownSession()
        guard desiredRunning else { return }
        restartWorkItem?.cancel()
        restartAttempt += 1
        let exponent = min(restartAttempt - 1, 6)
        let retryDelay = min(30.0, 0.5 * pow(2.0, Double(exponent)))
        let delay = requestedDelay ?? retryDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning else { return }
            do {
                try self.startSession()
            } catch {
                logVoiceDiagnostic("wake_restart_failed " + errorDiagnostic(error))
                self.errorHandler?(error)
                self.scheduleRestart()
            }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardownSession() {
        generation += 1
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        highPassFilter = nil
        isListening = false
    }
}

private func normalWindowInfo(forPID targetPID: pid_t) -> [String: Any]? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var bestMatch: ([String: Any], Double)?
    for info in windows {
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        guard layer == 0 else { continue }

        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard !ignoredWindowOwners.contains(owner) else { continue }

        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard alpha > 0.01 else { continue }

        guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        guard pid == Int(targetPID) else { continue }
        let title = info[kCGWindowName as String] as? String ?? ""
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue,
              width >= 160,
              height >= 100 else { continue }
        var result: [String: Any] = [
            "window_id": number.uint32Value,
            "owner": owner,
            "pid": pid,
            "title": title,
        ]
        result["bounds"] = bounds
        let area = width * height
        if bestMatch == nil || area > bestMatch!.1 {
            bestMatch = (result, area)
        }
    }
    return bestMatch?.0
}

private func normalFrontWindowInfo() -> [String: Any]? {
    guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
        return nil
    }
    return normalWindowInfo(forPID: frontmostPID)
}

private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var payload: [String: Any]?
    private var errorMessage: String?

    func succeed(_ value: [String: Any]) {
        lock.lock()
        payload = value
        finished = true
        lock.unlock()
    }

    func fail(_ message: String) {
        lock.lock()
        errorMessage = message
        finished = true
        lock.unlock()
    }

    func snapshot() -> (Bool, [String: Any]?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (finished, payload, errorMessage)
    }
}

private func pngData(from image: CGImage) throws -> Data {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Jarvis could not encode the captured window as PNG."]
        )
    }
    return data
}

private func requestedCaptureSize(for frame: CGRect) -> (Int, Int) {
    let width = max(1.0, frame.width)
    let height = max(1.0, frame.height)
    let longest = max(width, height)
    let scale = max(1.0, min(2.0, 4096.0 / longest))
    return (
        max(1, Int((width * scale).rounded())),
        max(1, Int((height * scale).rounded()))
    )
}

private func clearScreenCaptureError(_ error: Error) -> String {
    let detail = error.localizedDescription
    let lowered = detail.lowercased()
    if lowered.contains("declined tcc")
        || lowered.contains("not authorized")
        || lowered.contains("screen capture access") {
        return (
            "macOS denied Screen Recording for this exact signed Jarvis build. "
            + "Jarvis did not request permission again. In System Settings → Privacy & "
            + "Security → Screen & System Audio Recording, toggle Jarvis off and back on "
            + "once, then fully quit and reopen Jarvis."
        )
    }
    return detail
}

private func captureWindowImage(
    targetInfo: [String: Any],
    to destination: String,
    targetDescription: String
) throws -> [String: Any] {
    // On current macOS 26 builds CGPreflightScreenCaptureAccess can remain
    // false even while System Settings shows this signed app enabled. Treat
    // preflight as advisory and let ScreenCaptureKit make the authoritative
    // decision. This path runs only for an explicit capture/scan, never launch.
    if !CGPreflightScreenCaptureAccess() {
        logVoiceDiagnostic(
            "screen_capture_preflight_false attempting_screencapturekit=true"
        )
    }

    guard let targetNumber = targetInfo["window_id"] as? UInt32 else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 107,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Jarvis could not identify \(targetDescription)."
            ]
        )
    }

    let state = CaptureState()
    let destinationURL = URL(fileURLWithPath: destination)
    let targetID = CGWindowID(targetNumber)

    Task.detached(priority: .userInitiated) {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let targetWindow = content.windows.first(where: { $0.windowID == targetID }) else {
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(targetDescription.capitalized) disappeared before Jarvis could capture it."
                    ]
                )
            }

            let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            let configuration = SCStreamConfiguration()
            let size = requestedCaptureSize(for: targetWindow.frame)
            configuration.width = size.0
            configuration.height = size.1
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let data = try pngData(from: image)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)

            var payload = targetInfo
            payload["ok"] = true
            payload["path"] = destination
            payload["pixel_width"] = image.width
            payload["pixel_height"] = image.height
            payload["capture_engine"] = "Jarvis.app/ScreenCaptureKit"
            state.succeed(payload)
        } catch {
            state.fail(clearScreenCaptureError(error))
        }
    }

    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        let snapshot = state.snapshot()
        if snapshot.0 {
            if let payload = snapshot.1 {
                return payload
            }
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 108,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        snapshot.2 ?? "Jarvis could not capture \(targetDescription)."
                ]
            )
        }
        Thread.sleep(forTimeInterval: 0.03)
    }

    throw NSError(
        domain: jarvisBundleIdentifier,
        code: 109,
        userInfo: [
            NSLocalizedDescriptionKey:
                "Jarvis timed out while capturing \(targetDescription)."
        ]
    )
}

private func captureActiveWindowImage(to destination: String) throws -> [String: Any] {
    guard let targetInfo = normalFrontWindowInfo() else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 107,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Jarvis could not identify a normal frontmost application window."
            ]
        )
    }
    return try captureWindowImage(
        targetInfo: targetInfo,
        to: destination,
        targetDescription: "the active window"
    )
}

private func canonicalCaptureApplicationName(_ name: String) -> String {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch cleaned.lowercased() {
    case "trading view", "tradingview", "treating you", "trading you", "trading few":
        return "TradingView"
    case "chrome", "google chrome":
        return "Google Chrome"
    case "chat gpt", "chatgpt":
        return "ChatGPT"
    case "farm rpg", "farmrpg":
        return "Farm RPG"
    default:
        return cleaned
    }
}

private func captureNamedApplicationWindowImage(
    named requestedName: String,
    to destination: String
) throws -> [String: Any] {
    let targetName = canonicalCaptureApplicationName(requestedName)
    guard !targetName.isEmpty,
          targetName.count <= 80,
          !targetName.contains("/"),
          !targetName.contains("\\"),
          targetName.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 110,
            userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid application name."]
        )
    }

    let candidates = NSWorkspace.shared.runningApplications.filter { application in
        guard !application.isTerminated,
              let localizedName = application.localizedName else { return false }
        return localizedName.compare(targetName, options: [.caseInsensitive]) == .orderedSame
    }
    guard let targetApplication = candidates.first(where: { $0.activationPolicy == .regular })
            ?? candidates.first else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 111,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(targetName) is not open. Open it, then ask Jarvis to scan it again."
            ]
        )
    }
    guard let targetInfo = normalWindowInfo(forPID: targetApplication.processIdentifier) else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 112,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(targetName) is open but has no capturable window on the current desktop. "
                    + "Unminimize its window or move it to this desktop, then try again."
            ]
        )
    }

    let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var payload = try captureWindowImage(
        targetInfo: targetInfo,
        to: destination,
        targetDescription: "the \(targetName) window"
    )
    let frontmostPIDAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
    payload["requested_app"] = targetName
    payload["target_pid"] = Int(targetApplication.processIdentifier)
    payload["capture_scope"] = "named-app-window"
    payload["focus_preserved"] = frontmostPIDBefore != nil
        && frontmostPIDBefore == frontmostPIDAfter
    if let frontmostPIDBefore {
        payload["frontmost_pid_before"] = Int(frontmostPIDBefore)
    }
    if let frontmostPIDAfter {
        payload["frontmost_pid_after"] = Int(frontmostPIDAfter)
    }
    return payload
}

private func allowedCaptureDestination(_ rawPath: String) -> URL? {
    let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
    guard candidate.pathExtension.lowercased() == "png" else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = [
        home.appendingPathComponent("Jarvis/Information/Screenshots").standardizedFileURL,
        home.appendingPathComponent("Jarvis/Information/Trading/Chart Reviews").standardizedFileURL,
        URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL,
        URL(fileURLWithPath: "/private/tmp"),
        URL(fileURLWithPath: "/tmp"),
    ]
    return roots.contains(where: { candidate.path.hasPrefix($0.path + "/") })
        ? candidate : nil
}

private func allowedCaptureResponseURL(_ rawPath: String) -> URL? {
    let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
    guard candidate.lastPathComponent.hasPrefix("jarvis-capture-response-"),
          candidate.pathExtension.lowercased() == "json" else { return nil }
    let temporaryRoots = [
        URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL,
        URL(fileURLWithPath: "/private/tmp"),
        URL(fileURLWithPath: "/tmp"),
    ]
    return temporaryRoots.contains(where: { candidate.path.hasPrefix($0.path + "/") })
        ? candidate : nil
}

private func requestCaptureFromRunningApp(
    to destination: String,
    targetApplication: String? = nil
) -> Never {
    guard let destinationURL = allowedCaptureDestination(destination) else {
        failCLI("Jarvis rejected a capture destination outside its screenshot folders.")
    }
    let requestID = UUID().uuidString
    let responseURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jarvis-capture-response-\(requestID).json")
    try? FileManager.default.removeItem(at: responseURL)
    var requestInfo: [String: Any] = [
        "request_id": requestID,
        "destination": destinationURL.path,
        "response_path": responseURL.path,
    ]
    if let targetApplication {
        requestInfo["target_app"] = targetApplication
    }
    DistributedNotificationCenter.default().postNotificationName(
        activeWindowCaptureRequestNotification,
        object: nil,
        userInfo: requestInfo,
        deliverImmediately: true
    )

    let deadline = Date().addingTimeInterval(65)
    while Date() < deadline {
        if let data = try? Data(contentsOf: responseURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if payload["ok"] as? Bool == true {
                try? FileManager.default.removeItem(at: responseURL)
                writeJSON(payload)
            }
            let message = payload["error"] as? String
                ?? "The running Jarvis app could not capture the window."
            try? FileManager.default.removeItem(at: responseURL)
            failCLI(message)
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
    try? FileManager.default.removeItem(at: responseURL)
    failCLI("The running Jarvis app did not answer the screen-capture request.")
}

private func captureActiveWindow(to destination: String) -> Never {
    do {
        writeJSON(try captureActiveWindowImage(to: destination))
    } catch {
        failCLI(error.localizedDescription)
    }
}

private func runVoiceCaptureTest() -> Never {
    let recorder = PushToTalkRecorder()
    var stopRequested = false

    func stopAndReport() {
        guard !stopRequested else { return }
        stopRequested = true
        recorder.stop { result in
            switch result {
            case .success(let transcript):
                writeJSON([
                    "ok": true,
                    "transcript": transcript,
                    "words": transcriptWords(transcript).count,
                ])
            case .failure(let error):
                failCLI(error.localizedDescription)
            }
        }
    }

    recorder.authorizeAndStart(
        onSilenceDetected: stopAndReport,
        completion: { result in
            if case .failure(let error) = result {
                failCLI(error.localizedDescription)
            }
        }
    )

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    recorder.cancel()
    failCLI("Jarvis timed out while testing live voice capture.")
}

private func runWakeCaptureTest() -> Never {
    let listener = WakeWordListener()
    do {
        try listener.start(
            onDetected: { sampleURL in
                if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
                writeJSON(["ok": true, "command": "", "words": 0])
            },
            onWakeWordHeard: {},
            onSiriWakeWord: {
                writeJSON(["ok": true, "siri": true])
            },
            onCommandDetected: { command, sampleURL in
                if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
                writeJSON([
                    "ok": true,
                    "command": command,
                    "words": transcriptWords(command).count,
                ])
            },
            onError: { error in
                failCLI(error.localizedDescription)
            }
        )
    } catch {
        failCLI(error.localizedDescription)
    }

    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    listener.stop()
    failCLI("Jarvis timed out while testing wake-word capture.")
}

private func postDistributedRequest(_ name: Notification.Name) {
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    // Delivery is asynchronous, so do not let this short-lived helper exit
    // before macOS has accepted the notification.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}

private func handleCommandLineMode() {
    guard CommandLine.arguments.count > 1 else { return }
    let command = CommandLine.arguments[1]

    if command == "--run-live-voice-test" {
        return
    }

    switch command {
    case "--request-tradingview-ny-fib":
        postDistributedRequest(tradingViewNYFibDiagnosticNotification)
        writeJSON(["ok": true, "requested": true])
    case "--request-tradingview-review-capture":
        postDistributedRequest(tradingViewReviewDiagnosticNotification)
        writeJSON(["ok": true, "requested": true])
    case "--request-live-voice-test":
        postDistributedRequest(liveVoiceDiagnosticNotification)
        writeJSON(["ok": true, "requested": true])
    case "--test-spoken-response":
        postDistributedRequest(testSpokenResponseNotification)
        writeJSON(["ok": true, "requested": true])
    case "--accessibility-permission-status":
        writeJSON([
            "bundle_id": jarvisBundleIdentifier,
            "ax_trusted": AXIsProcessTrusted(),
            "event_posting": CGPreflightPostEventAccess(),
        ])
    case "--request-accessibility-permission":
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let axTrusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        let eventPosting = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        writeJSON([
            "bundle_id": jarvisBundleIdentifier,
            "ax_trusted": axTrusted,
            "event_posting": eventPosting,
        ])
    case "--screen-permission-status":
        writeJSON([
            "bundle_id": jarvisBundleIdentifier,
            "granted": CGPreflightScreenCaptureAccess(),
        ])
    case "--request-screen-permission":
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        writeJSON([
            "bundle_id": jarvisBundleIdentifier,
            "granted": granted,
        ])
    case "--capture-active-window":
        guard CommandLine.arguments.count > 2 else {
            failCLI("A destination path is required.")
        }
        requestCaptureFromRunningApp(to: CommandLine.arguments[2])
    case "--capture-app-window":
        guard CommandLine.arguments.count > 3 else {
            failCLI("An open application name and destination path are required.")
        }
        requestCaptureFromRunningApp(
            to: CommandLine.arguments[3],
            targetApplication: CommandLine.arguments[2]
        )
    case "--login-item-status":
        writeJSON([
            "bundle_id": jarvisBundleIdentifier,
            "status": loginItemStatusName(SMAppService.mainApp.status),
        ])
    case "--set-login-item":
        guard CommandLine.arguments.count > 2 else {
            failCLI("Use enabled or disabled.")
        }
        let requested = CommandLine.arguments[2].lowercased()
        guard requested == "enabled" || requested == "disabled" else {
            failCLI("Use enabled or disabled.")
        }
        do {
            let status = try setLoginItemEnabled(requested == "enabled")
            writeJSON([
                "bundle_id": jarvisBundleIdentifier,
                "status": loginItemStatusName(status),
            ])
        } catch {
            failCLI("Could not update the login item: \(error.localizedDescription)")
        }
    case "--login-item-plan":
        guard CommandLine.arguments.count > 3 else {
            failCLI("A current status and enabled or disabled are required.")
        }
        let requested = CommandLine.arguments[3].lowercased()
        guard requested == "enabled" || requested == "disabled" else {
            failCLI("Use enabled or disabled.")
        }
        writeJSON([
            "plan": loginItemPlan(
                statusName: CommandLine.arguments[2],
                enable: requested == "enabled"
            ),
        ])
    case "--voice-shortcut-status":
        let enabled = UserDefaults.standard.object(forKey: voiceShortcutDefaultsKey) == nil
            ? true : UserDefaults.standard.bool(forKey: voiceShortcutDefaultsKey)
        writeJSON(["enabled": enabled])
    case "--set-voice-shortcut":
        guard CommandLine.arguments.count > 2 else {
            failCLI("Use enabled or disabled.")
        }
        let requested = CommandLine.arguments[2].lowercased()
        guard requested == "enabled" || requested == "disabled" else {
            failCLI("Use enabled or disabled.")
        }
        UserDefaults.standard.set(requested == "enabled", forKey: voiceShortcutDefaultsKey)
        writeJSON(["enabled": requested == "enabled"])
    case "--voice-permission-status":
        writeJSON([
            "microphone": microphoneAuthorizationName(
                AVCaptureDevice.authorizationStatus(for: .audio)
            ),
            "speech_recognition": speechAuthorizationName(
                SFSpeechRecognizer.authorizationStatus()
            ),
        ])
    case "--audio-device-status":
        writeJSON([
            "default_input": defaultInputDeviceName(),
            "input_devices": audioInputDeviceIDs().compactMap(audioDeviceName),
            "preferred_razer_connected": preferredRazerMicrophoneID() != nil,
        ])
    case "--render-presence-preview":
        do {
            let state = presenceState(
                named: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
            )
            let previewURL = try renderPresencePreview(state: state)
            writeJSON(["path": previewURL.path, "state": state.label.lowercased()])
        } catch {
            failCLI("Could not render the Jarvis presence preview: \(error.localizedDescription)")
        }
    case "--preview-presence-live":
        DistributedNotificationCenter.default().postNotificationName(
            presencePreviewNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        writeJSON(["requested": true, "target": "running Jarvis presence"])
    case "--prefer-razer-microphone":
        let selected = makeRazerMicrophoneDefaultInput()
        writeJSON([
            "selected": selected,
            "default_input": defaultInputDeviceName(),
        ], exitCode: selected ? 0 : 1)
    case "--voice-capture-test":
        runVoiceCaptureTest()
    case "--modern-speech-file-test":
        guard CommandLine.arguments.count > 2 else {
            failCLI("An audio file path is required.")
        }
        runModernSpeechFileTest(CommandLine.arguments[2])
    case "--wake-capture-test":
        runWakeCaptureTest()
    case "--parse-wake-transcript":
        guard CommandLine.arguments.count > 2 else {
            failCLI("A wake transcript is required.")
        }
        let transcript = CommandLine.arguments[2]
        if let command = wakeCommandAfterWakeWord(transcript) {
            writeJSON(["detected": true, "command": command])
        }
        writeJSON(["detected": false, "command": ""])
    case "--voice-endpoint-decision":
        guard CommandLine.arguments.count > 5,
              let acousticQuiet = Double(CommandLine.arguments[3]),
              let transcriptQuiet = Double(CommandLine.arguments[4]),
              let recognizedFor = Double(CommandLine.arguments[5]) else {
            failCLI(
                "Use --voice-endpoint-decision <transcript> <acoustic-quiet> "
                + "<transcript-quiet> <recognized-for>."
            )
        }
        let endpointTranscript = CommandLine.arguments[2]
        writeJSON([
            "finalize": shouldFinalizeRecognizedCommand(
                transcript: endpointTranscript,
                acousticQuietFor: acousticQuiet,
                transcriptQuietFor: transcriptQuiet,
                recognizedFor: recognizedFor
            ),
            "required_silence": commandEndSilenceSeconds(endpointTranscript),
            "words": transcriptWords(endpointTranscript).count,
        ])
    case "--voice-acoustic-endpoint-decision":
        guard CommandLine.arguments.count > 4,
              let quiet = Double(CommandLine.arguments[3]),
              let duration = Double(CommandLine.arguments[4]) else {
            failCLI(
                "Use --voice-acoustic-endpoint-decision <true-or-false> "
                + "<acoustic-quiet> <speech-duration>."
            )
        }
        writeJSON([
            "finalize": shouldFinalizeAcousticFallback(
                heardAcousticSpeech: CommandLine.arguments[2].lowercased() == "true",
                acousticQuietFor: quiet,
                acousticSpeechFor: duration
            ),
        ])
    case "--voice-unrecognized-audio-endpoint-decision":
        guard CommandLine.arguments.count > 3,
              let elapsed = Double(CommandLine.arguments[3]) else {
            failCLI(
                "Use --voice-unrecognized-audio-endpoint-decision "
                + "<has-recognized-speech> <elapsed>."
            )
        }
        writeJSON([
            "finalize": shouldFinalizeUnrecognizedAudio(
                hasRecognizedSpeech: CommandLine.arguments[2].lowercased() == "true",
                elapsed: elapsed
            ),
        ])
    case "--voice-reported-final-endpoint-decision":
        guard CommandLine.arguments.count > 5,
              let quiet = Double(CommandLine.arguments[3]),
              let transcriptQuiet = Double(CommandLine.arguments[4]) else {
            failCLI(
                "Use --voice-reported-final-endpoint-decision <transcript> "
                + "<acoustic-quiet> <transcript-quiet> <true-or-false>."
            )
        }
        writeJSON([
            "finalize": shouldFinalizeReportedFinal(
                transcript: CommandLine.arguments[2],
                isFinal: CommandLine.arguments[5].lowercased() == "true",
                acousticQuietFor: quiet,
                transcriptQuietFor: transcriptQuiet
            ),
        ])
    case "--prefer-transcript":
        guard CommandLine.arguments.count > 4 else {
            failCLI("Use --prefer-transcript <current> <candidate> <true-or-false>.")
        }
        writeJSON([
            "transcript": preferredTranscript(
                current: CommandLine.arguments[2],
                candidate: CommandLine.arguments[3],
                isFinal: CommandLine.arguments[4].lowercased() == "true"
            ),
        ])
    case "--prefer-recognition-candidate":
        guard CommandLine.arguments.count > 3 else {
            failCLI("Use --prefer-recognition-candidate <modern> <legacy>.")
        }
        let candidate = preferredRecognitionCandidate(
            modern: CommandLine.arguments[2],
            legacy: CommandLine.arguments[3]
        )
        writeJSON([
            "transcript": normalizeRecognizedTranscript(candidate.transcript),
            "engine": candidate.engine,
        ])
    case "--normalize-voice-transcript":
        guard CommandLine.arguments.count > 2 else {
            failCLI("A voice transcript is required.")
        }
        writeJSON([
            "transcript": normalizeRecognizedTranscript(CommandLine.arguments[2]),
        ])
    default:
        failCLI("Unknown Jarvis.app command: \(command)")
    }
}

if CommandLine.arguments.count > 1 {
    handleCommandLineMode()
}

// Legacy menu-item artwork retained only as a self-contained reference. It is
// intentionally never attached to the status item; the presence HUD below is
// the single owner of animated voice feedback. Keeping one visual owner avoids
// the historical bug where a small spinner continued after the HUD dismissed.
private final class JarvisEnergyOrbView: NSView {
    private let haloLayer = CAGradientLayer()
    private let haloMaskLayer = CAShapeLayer()
    private let coreLayer = CAGradientLayer()
    private let coreMaskLayer = CAShapeLayer()
    private let outerArcLayer = CAShapeLayer()
    private let innerArcLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        isHidden = true

        haloLayer.type = .radial
        haloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        haloLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        haloLayer.colors = [
            NSColor.systemCyan.withAlphaComponent(0.52).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.42).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.16).cgColor,
            NSColor.clear.cgColor,
        ]
        haloLayer.locations = [0.0, 0.56, 0.82, 1.0]
        haloLayer.mask = haloMaskLayer

        coreLayer.type = .radial
        coreLayer.startPoint = CGPoint(x: 0.40, y: 0.36)
        coreLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        coreLayer.colors = [
            NSColor.white.cgColor,
            NSColor.systemCyan.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor(calibratedRed: 0.01, green: 0.10, blue: 0.58, alpha: 1.0).cgColor,
        ]
        coreLayer.locations = [0.0, 0.18, 0.56, 1.0]
        coreLayer.mask = coreMaskLayer

        outerArcLayer.fillColor = NSColor.clear.cgColor
        outerArcLayer.strokeColor = NSColor.systemCyan.withAlphaComponent(0.98).cgColor
        outerArcLayer.lineWidth = 1.45
        outerArcLayer.lineCap = .round
        outerArcLayer.strokeStart = 0.04
        outerArcLayer.strokeEnd = 0.58

        innerArcLayer.fillColor = NSColor.clear.cgColor
        innerArcLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.96).cgColor
        innerArcLayer.lineWidth = 1.0
        innerArcLayer.lineCap = .round
        innerArcLayer.strokeStart = 0.64
        innerArcLayer.strokeEnd = 0.91

        layer?.addSublayer(haloLayer)
        layer?.addSublayer(coreLayer)
        layer?.addSublayer(outerArcLayer)
        layer?.addSublayer(innerArcLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("JarvisEnergyOrbView does not support Interface Builder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let diameter = min(20.0, max(16.0, min(bounds.width, bounds.height) - 1.5))
        let orbRect = CGRect(
            x: bounds.midX - diameter / 2.0,
            y: bounds.midY - diameter / 2.0,
            width: diameter,
            height: diameter
        )
        let coreRect = orbRect.insetBy(dx: 2.25, dy: 2.25)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.frame = orbRect
        haloMaskLayer.frame = CGRect(origin: .zero, size: orbRect.size)
        haloMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: orbRect.size),
            transform: nil
        )
        coreLayer.frame = coreRect
        coreMaskLayer.frame = CGRect(origin: .zero, size: coreRect.size)
        coreMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: coreRect.size),
            transform: nil
        )
        outerArcLayer.frame = bounds
        outerArcLayer.path = CGPath(
            ellipseIn: orbRect.insetBy(dx: 1.05, dy: 1.05),
            transform: nil
        )
        innerArcLayer.frame = bounds
        innerArcLayer.path = CGPath(
            ellipseIn: orbRect.insetBy(dx: 3.35, dy: 3.35),
            transform: nil
        )
        CATransaction.commit()
    }

    func startAnimating() {
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard outerArcLayer.animation(forKey: "jarvis.outerSpin") == nil else { return }

        let outerSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        outerSpin.byValue = Double.pi * 2.0
        outerSpin.duration = 1.05
        outerSpin.repeatCount = .infinity
        outerSpin.timingFunction = CAMediaTimingFunction(name: .linear)
        outerArcLayer.add(outerSpin, forKey: "jarvis.outerSpin")

        let innerSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        innerSpin.byValue = -Double.pi * 2.0
        innerSpin.duration = 0.72
        innerSpin.repeatCount = .infinity
        innerSpin.timingFunction = CAMediaTimingFunction(name: .linear)
        innerArcLayer.add(innerSpin, forKey: "jarvis.innerSpin")

        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [0.94, 1.06, 0.97, 1.03, 0.94]
        pulse.keyTimes = [0.0, 0.22, 0.52, 0.76, 1.0]
        pulse.duration = 1.20
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloLayer.add(pulse, forKey: "jarvis.pulse")

        let energy = CAKeyframeAnimation(keyPath: "opacity")
        energy.values = [0.78, 1.0, 0.86, 1.0, 0.78]
        energy.keyTimes = [0.0, 0.20, 0.48, 0.72, 1.0]
        energy.duration = 0.84
        energy.repeatCount = .infinity
        coreLayer.add(energy, forKey: "jarvis.energy")
    }

    func stopAnimating() {
        haloLayer.removeAllAnimations()
        coreLayer.removeAllAnimations()
        outerArcLayer.removeAllAnimations()
        innerArcLayer.removeAllAnimations()
        isHidden = true
    }
}

private enum JarvisPresenceState {
    case standby
    case awakening
    case listening
    case thinking
    case speaking
    case capturing
    case rejected

    var label: String {
        switch self {
        case .standby: return "AWAKE"
        case .awakening: return "ONLINE"
        case .listening: return "LISTENING"
        case .thinking: return "REASONING"
        case .speaking: return "RESPONDING"
        case .capturing: return "OBSERVING"
        case .rejected: return "VOICE NOT VERIFIED"
        }
    }

    var color: NSColor {
        switch self {
        case .standby: return .systemCyan
        case .awakening: return .systemCyan
        case .listening: return .systemBlue
        case .thinking: return .systemPurple
        case .speaking: return .systemGreen
        case .capturing: return .systemOrange
        case .rejected: return .systemRed
        }
    }

    var secondaryColor: NSColor {
        switch self {
        case .standby, .awakening: return .systemBlue
        case .listening: return .systemTeal
        case .thinking: return .systemPink
        case .speaking: return .systemCyan
        case .capturing: return .systemYellow
        case .rejected: return .systemOrange
        }
    }

    var panelSide: CGFloat { self == .standby ? 112 : 248 }
    var isCompact: Bool { self == .standby }

    var activityGlyph: String {
        switch self {
        case .standby: return "●"
        case .awakening: return "◇"
        case .listening: return "◉"
        case .thinking: return "✦"
        case .speaking: return "◈"
        case .capturing: return "◎"
        case .rejected: return "×"
        }
    }
}

/// GPU-composited visual state machine for Jarvis's top-right presence.
///
/// Architecture and maintenance invariants:
/// - Every moving element is a GPU-composited Core Animation CALayer. Never add a permanent Timer,
///   display link, per-frame draw loop, Metal view, or continuous audio polling.
/// - `.standby` is a compact ambient state; all command states expand the same
///   NSPanel. Do not create a second overlay or animate the menu-bar icon.
/// - Motion is semantic: listening and speaking emphasize the signal ring,
///   thinking accelerates counter-rotation, observing emphasizes the sweep, and
///   rejection contracts/shakes. State labels remain the non-color cue.
/// - Reduce Motion and Reduce Transparency are queried from NSWorkspace.
/// - JarvisPresenceHUDController owns dismissal generations so a delayed result
///   cannot collapse a newer listening/thinking state.
///
/// See docs/JARVIS_PRESENCE_SYSTEM.md before changing geometry or lifecycle.
private final class JarvisPresenceView: NSView {
    private let backdropLayer = CAGradientLayer()
    private let spectralHaloLayer = CAGradientLayer()
    private let horizonLayer = CAShapeLayer()
    private let fieldLayer = CAShapeLayer()
    private let coronaReplicator = CAReplicatorLayer()
    private let coronaSourceLayer = CAShapeLayer()
    private let outerRingLayer = CAShapeLayer()
    private let middleRingLayer = CAShapeLayer()
    private let innerRingLayer = CAShapeLayer()
    private let dataArcLayers = (0..<4).map { _ in CAShapeLayer() }
    private let energyRibbonLayers = (0..<2).map { _ in CAShapeLayer() }
    private let neuralFilamentLayer = CAShapeLayer()
    private let neuralEchoLayer = CAShapeLayer()
    private let waveformLayer = CAShapeLayer()
    private let waveformEchoLayer = CAShapeLayer()
    private let sweepLayer = CAGradientLayer()
    private let sweepMaskLayer = CAShapeLayer()
    private let gyroscopeContainers = (0..<3).map { _ in CALayer() }
    private let gyroscopeRingLayers = (0..<3).map { _ in CAShapeLayer() }
    private let coreLayer = CAGradientLayer()
    private let coreMaskLayer = CAShapeLayer()
    private let plasmaContainerLayer = CALayer()
    private let plasmaMaskLayer = CAShapeLayer()
    private let plasmaLayers = (0..<6).map { _ in CAGradientLayer() }
    private let lensLayer = CAGradientLayer()
    private let lensMaskLayer = CAShapeLayer()
    private let irisLayer = CAGradientLayer()
    private let irisMaskLayer = CAShapeLayer()
    private let pupilLayer = CAGradientLayer()
    private let glintLayer = CAGradientLayer()
    private let photonReplicator = CAReplicatorLayer()
    private let photonSourceLayer = CAShapeLayer()
    private let sparkReplicator = CAReplicatorLayer()
    private let sparkSourceLayer = CAShapeLayer()
    private let pulseReplicator = CAReplicatorLayer()
    private let pulseSourceLayer = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let stateLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private var currentState: JarvisPresenceState = .awakening

    private var allowsCinematicMotion: Bool {
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled else { return false }
        switch processInfo.thermalState {
        case .serious, .critical: return false
        case .nominal, .fair: return true
        @unknown default: return false
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)

        backdropLayer.type = .radial
        backdropLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        backdropLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        backdropLayer.colors = [
            NSColor(calibratedWhite: 0.015, alpha: 0.96).cgColor,
            NSColor(calibratedRed: 0.005, green: 0.045, blue: 0.09, alpha: 0.91).cgColor,
            NSColor.clear.cgColor,
        ]
        backdropLayer.locations = [0.0, 0.66, 1.0]

        spectralHaloLayer.type = .radial
        spectralHaloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        spectralHaloLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        spectralHaloLayer.locations = [0.0, 0.30, 0.58, 0.82, 1.0]
        spectralHaloLayer.compositingFilter = "screenBlendMode"

        horizonLayer.fillColor = NSColor.clear.cgColor
        horizonLayer.lineWidth = 0.65
        horizonLayer.lineDashPattern = [1, 8]

        for ring in [fieldLayer, outerRingLayer, middleRingLayer, innerRingLayer] {
            ring.fillColor = NSColor.clear.cgColor
            ring.lineCap = .round
        }
        fieldLayer.lineWidth = 0.7
        fieldLayer.lineDashPattern = [1, 5]
        coronaReplicator.instanceCount = 36
        coronaReplicator.instanceAlphaOffset = -0.014
        coronaReplicator.addSublayer(coronaSourceLayer)
        coronaSourceLayer.fillColor = NSColor.clear.cgColor
        coronaSourceLayer.lineWidth = 0.72
        coronaSourceLayer.lineCap = .round
        outerRingLayer.lineWidth = 2.0
        outerRingLayer.lineDashPattern = [22, 7, 3, 8]
        middleRingLayer.lineWidth = 1.1
        middleRingLayer.lineDashPattern = [8, 5, 2, 7]
        innerRingLayer.lineWidth = 1.8
        innerRingLayer.strokeStart = 0.06
        innerRingLayer.strokeEnd = 0.72

        for (index, arc) in dataArcLayers.enumerated() {
            arc.fillColor = NSColor.clear.cgColor
            arc.lineWidth = index.isMultiple(of: 2) ? 1.05 : 0.72
            arc.lineCap = .round
            arc.strokeStart = 0.05 + CGFloat(index) * 0.11
            arc.strokeEnd = min(0.94, arc.strokeStart + 0.18 + CGFloat(index) * 0.035)
            arc.lineDashPattern = index.isMultiple(of: 2) ? [5, 2, 1, 4] : [2, 6]
        }

        for (index, ribbon) in energyRibbonLayers.enumerated() {
            ribbon.fillColor = NSColor.clear.cgColor
            ribbon.lineWidth = index == 0 ? 1.35 : 0.82
            ribbon.lineCap = .round
            ribbon.lineJoin = .round
            ribbon.lineDashPattern = index == 0 ? nil : [2, 3, 7, 4]
            ribbon.compositingFilter = "screenBlendMode"
        }

        neuralFilamentLayer.fillColor = NSColor.clear.cgColor
        neuralFilamentLayer.lineWidth = 1.05
        neuralFilamentLayer.lineCap = .round
        neuralFilamentLayer.lineJoin = .round
        neuralFilamentLayer.lineDashPattern = [3, 2, 1, 4]

        neuralEchoLayer.fillColor = NSColor.clear.cgColor
        neuralEchoLayer.lineWidth = 0.58
        neuralEchoLayer.lineCap = .round
        neuralEchoLayer.lineJoin = .round
        neuralEchoLayer.lineDashPattern = [1, 4, 6, 3]

        waveformLayer.fillColor = NSColor.clear.cgColor
        waveformLayer.lineWidth = 0.85
        waveformLayer.lineCap = .round

        waveformEchoLayer.fillColor = NSColor.clear.cgColor
        waveformEchoLayer.lineWidth = 0.55
        waveformEchoLayer.lineCap = .round
        waveformEchoLayer.lineDashPattern = [1, 3]

        sweepLayer.type = .conic
        sweepLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        sweepLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.systemCyan.withAlphaComponent(0.34).cgColor,
            NSColor.clear.cgColor,
        ]
        sweepLayer.locations = [0.0, 0.70, 0.92, 1.0]
        sweepLayer.mask = sweepMaskLayer

        for (container, ring) in zip(gyroscopeContainers, gyroscopeRingLayers) {
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 0.72
            ring.lineCap = .round
            ring.lineDashPattern = [2, 5, 11, 4]
            container.addSublayer(ring)
        }

        coreLayer.type = .radial
        coreLayer.startPoint = CGPoint(x: 0.38, y: 0.34)
        coreLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        coreLayer.mask = coreMaskLayer

        plasmaContainerLayer.mask = plasmaMaskLayer
        plasmaContainerLayer.masksToBounds = false
        let plasmaPalettes: [[CGColor]] = [
            [NSColor.white.withAlphaComponent(0.92).cgColor, NSColor.systemCyan.withAlphaComponent(0.72).cgColor, NSColor.clear.cgColor],
            [NSColor.systemBlue.withAlphaComponent(0.88).cgColor, NSColor.systemPurple.withAlphaComponent(0.48).cgColor, NSColor.clear.cgColor],
            [NSColor.systemTeal.withAlphaComponent(0.68).cgColor, NSColor.systemBlue.withAlphaComponent(0.38).cgColor, NSColor.clear.cgColor],
            [NSColor.systemPink.withAlphaComponent(0.48).cgColor, NSColor.systemPurple.withAlphaComponent(0.32).cgColor, NSColor.clear.cgColor],
            [NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.systemBlue.withAlphaComponent(0.52).cgColor, NSColor.clear.cgColor],
            [NSColor.systemCyan.withAlphaComponent(0.42).cgColor, NSColor.systemPink.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor],
        ]
        for (index, plasma) in plasmaLayers.enumerated() {
            plasma.type = .radial
            plasma.startPoint = CGPoint(x: 0.34 + CGFloat(index % 2) * 0.24, y: 0.30 + CGFloat(index / 2) * 0.28)
            plasma.endPoint = CGPoint(x: 0.90, y: 0.90)
            plasma.colors = plasmaPalettes[index]
            plasma.locations = [0.0, 0.38, 1.0]
            plasma.compositingFilter = "screenBlendMode"
            plasmaContainerLayer.addSublayer(plasma)
        }

        lensLayer.type = .conic
        lensLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        lensLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        lensLayer.locations = [0.0, 0.14, 0.28, 0.47, 0.66, 0.84, 1.0]
        lensLayer.compositingFilter = "screenBlendMode"
        lensLayer.mask = lensMaskLayer

        irisLayer.type = .radial
        irisLayer.startPoint = CGPoint(x: 0.42, y: 0.38)
        irisLayer.endPoint = CGPoint(x: 0.88, y: 0.88)
        irisLayer.colors = [
            NSColor.white.withAlphaComponent(0.88).cgColor,
            NSColor.systemCyan.withAlphaComponent(0.30).cgColor,
            NSColor.clear.cgColor,
        ]
        irisLayer.locations = [0.0, 0.22, 1.0]
        irisLayer.mask = irisMaskLayer

        pupilLayer.type = .radial
        pupilLayer.startPoint = CGPoint(x: 0.38, y: 0.38)
        pupilLayer.endPoint = CGPoint(x: 0.94, y: 0.94)
        pupilLayer.colors = [
            NSColor.white.withAlphaComponent(0.96).cgColor,
            NSColor.systemCyan.withAlphaComponent(0.52).cgColor,
            NSColor.clear.cgColor,
        ]
        pupilLayer.locations = [0.0, 0.24, 1.0]
        pupilLayer.compositingFilter = "screenBlendMode"

        glintLayer.type = .radial
        glintLayer.colors = [
            NSColor.white.withAlphaComponent(0.94).cgColor,
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor,
        ]
        glintLayer.locations = [0.0, 0.24, 1.0]

        photonReplicator.instanceCount = 24
        photonReplicator.instanceAlphaOffset = -0.032
        photonReplicator.addSublayer(photonSourceLayer)
        photonSourceLayer.fillColor = NSColor.white.withAlphaComponent(0.90).cgColor

        sparkReplicator.instanceCount = 12
        sparkReplicator.instanceAlphaOffset = -0.052
        sparkSourceLayer.fillColor = NSColor.white.withAlphaComponent(0.82).cgColor
        sparkReplicator.addSublayer(sparkSourceLayer)

        pulseReplicator.instanceCount = 3
        pulseReplicator.instanceDelay = 0.42
        pulseSourceLayer.fillColor = NSColor.clear.cgColor
        pulseSourceLayer.lineWidth = 1.2
        pulseReplicator.addSublayer(pulseSourceLayer)

        titleLayer.string = "J A R V I S"
        titleLayer.alignmentMode = .center
        titleLayer.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLayer.fontSize = 12
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        titleLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        stateLayer.alignmentMode = .center
        stateLayer.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        stateLayer.fontSize = 9
        stateLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        detailLayer.string = "LOCAL  •  PRIVATE  •  READY"
        detailLayer.alignmentMode = .center
        detailLayer.font = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)
        detailLayer.fontSize = 7.5
        detailLayer.foregroundColor = NSColor.white.withAlphaComponent(0.46).cgColor
        detailLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        layer?.addSublayer(backdropLayer)
        layer?.addSublayer(spectralHaloLayer)
        layer?.addSublayer(horizonLayer)
        layer?.addSublayer(fieldLayer)
        layer?.addSublayer(coronaReplicator)
        layer?.addSublayer(sweepLayer)
        layer?.addSublayer(pulseReplicator)
        layer?.addSublayer(outerRingLayer)
        for arc in dataArcLayers { layer?.addSublayer(arc) }
        layer?.addSublayer(middleRingLayer)
        for ribbon in energyRibbonLayers { layer?.addSublayer(ribbon) }
        layer?.addSublayer(neuralEchoLayer)
        layer?.addSublayer(neuralFilamentLayer)
        layer?.addSublayer(waveformEchoLayer)
        layer?.addSublayer(waveformLayer)
        for container in gyroscopeContainers { layer?.addSublayer(container) }
        layer?.addSublayer(innerRingLayer)
        layer?.addSublayer(coreLayer)
        layer?.addSublayer(plasmaContainerLayer)
        layer?.addSublayer(lensLayer)
        layer?.addSublayer(irisLayer)
        layer?.addSublayer(pupilLayer)
        layer?.addSublayer(glintLayer)
        layer?.addSublayer(photonReplicator)
        layer?.addSublayer(sparkReplicator)
        layer?.addSublayer(titleLayer)
        layer?.addSublayer(stateLayer)
        layer?.addSublayer(detailLayer)
        configure(for: .awakening)
    }

    required init?(coder: NSCoder) {
        fatalError("JarvisPresenceView does not support Interface Builder")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let compact = currentState.isCompact || min(bounds.width, bounds.height) < 170
        let center = CGPoint(x: bounds.midX, y: bounds.midY + (compact ? 0 : 15))
        let outerDiameter = compact
            ? max(72, min(bounds.width, bounds.height) - 20)
            : min(170, min(bounds.width - 40, bounds.height - 68))
        let outerRect = CGRect(
            x: center.x - outerDiameter / 2,
            y: center.y - outerDiameter / 2,
            width: outerDiameter,
            height: outerDiameter
        )
        let middleRect = outerRect.insetBy(dx: outerDiameter * 0.085, dy: outerDiameter * 0.085)
        let innerRect = outerRect.insetBy(dx: outerDiameter * 0.205, dy: outerDiameter * 0.205)
        let coreInset = outerDiameter * (compact ? 0.28 : 0.265)
        let coreRect = outerRect.insetBy(dx: coreInset, dy: coreInset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        spectralHaloLayer.frame = outerRect.insetBy(dx: -22, dy: -22)
        for item in [
            horizonLayer, fieldLayer, outerRingLayer, middleRingLayer,
            innerRingLayer, neuralFilamentLayer, neuralEchoLayer,
            waveformLayer, waveformEchoLayer,
        ] {
            item.frame = bounds
        }
        let horizonPath = CGMutablePath()
        for inset in stride(from: CGFloat(1), through: CGFloat(15), by: 7) {
            horizonPath.addEllipse(in: outerRect.insetBy(dx: -inset, dy: -inset))
        }
        horizonLayer.path = horizonPath
        fieldLayer.path = CGPath(ellipseIn: outerRect.insetBy(dx: -6, dy: -6), transform: nil)
        coronaReplicator.frame = bounds
        coronaReplicator.instanceCount = compact ? 18 : 36
        coronaReplicator.instanceTransform = CATransform3DMakeRotation(
            (2 * .pi) / Double(coronaReplicator.instanceCount), 0, 0, 1
        )
        coronaSourceLayer.frame = bounds
        let coronaPath = CGMutablePath()
        coronaPath.move(to: CGPoint(x: center.x, y: outerRect.maxY + 1))
        coronaPath.addLine(
            to: CGPoint(x: center.x, y: outerRect.maxY + (compact ? 4 : 13))
        )
        coronaSourceLayer.path = coronaPath
        outerRingLayer.path = CGPath(ellipseIn: outerRect, transform: nil)
        middleRingLayer.path = CGPath(ellipseIn: middleRect, transform: nil)
        innerRingLayer.path = CGPath(ellipseIn: innerRect, transform: nil)
        for (index, arc) in dataArcLayers.enumerated() {
            arc.frame = bounds
            let inset = CGFloat(3 + index * 7)
            arc.path = CGPath(
                ellipseIn: outerRect.insetBy(dx: inset, dy: inset),
                transform: nil
            )
            arc.isHidden = compact
        }
        energyRibbonLayers[0].frame = bounds
        energyRibbonLayers[0].path = organicRingPath(
            in: middleRect.insetBy(dx: 1, dy: 1),
            amplitude: 5.7,
            lobes: currentState == .thinking ? 17 : 11,
            phase: 1.24
        )
        energyRibbonLayers[1].frame = bounds
        energyRibbonLayers[1].path = organicRingPath(
            in: middleRect.insetBy(dx: 8, dy: 8),
            amplitude: 3.8,
            lobes: currentState == .speaking ? 19 : 14,
            phase: -0.72
        )
        for ribbon in energyRibbonLayers { ribbon.isHidden = compact }
        neuralFilamentLayer.path = organicRingPath(
            in: middleRect.insetBy(dx: 5, dy: 5),
            amplitude: compact ? 1.8 : 3.6,
            lobes: currentState == .thinking ? 13 : 9,
            phase: currentState == .listening ? 0.65 : 0.15
        )
        neuralEchoLayer.path = organicRingPath(
            in: middleRect.insetBy(dx: 11, dy: 11),
            amplitude: compact ? 1.0 : 2.5,
            lobes: currentState == .thinking ? 21 : 16,
            phase: -1.05
        )
        neuralEchoLayer.isHidden = compact
        waveformLayer.path = radialSignalPath(
            around: innerRect.insetBy(dx: -5, dy: -5),
            amplitude: compact ? 2.0 : signalAmplitude(for: currentState)
        )
        waveformEchoLayer.path = radialSignalPath(
            around: innerRect.insetBy(dx: 5, dy: 5),
            amplitude: compact ? 0.8 : signalAmplitude(for: currentState) * 0.48,
            phase: 1.8,
            frequency: currentState == .speaking ? 17 : 13
        )
        waveformEchoLayer.isHidden = compact
        sweepLayer.frame = outerRect
        sweepMaskLayer.frame = CGRect(origin: .zero, size: outerRect.size)
        sweepMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: outerRect.size).insetBy(dx: 8, dy: 8),
            transform: nil
        )
        sweepMaskLayer.fillColor = NSColor.white.cgColor
        for (index, pair) in zip(gyroscopeContainers, gyroscopeRingLayers).enumerated() {
            let (container, ring) = pair
            container.frame = bounds
            ring.frame = bounds
            let gyroInset = CGFloat(index) * 4.5
            ring.path = CGPath(
                ellipseIn: innerRect.insetBy(dx: -7 + gyroInset, dy: -7 + gyroInset),
                transform: nil
            )
            var tilt = CATransform3DIdentity
            tilt.m34 = -1.0 / 460.0
            let angles: [(CGFloat, CGFloat, CGFloat)] = [
                (0.98, 1, 0), (-0.82, 0, 1), (0.61, 1, 1),
            ]
            let values = angles[index]
            tilt = CATransform3DRotate(tilt, values.0, values.1, values.2, 0)
            container.transform = tilt
            container.isHidden = compact
        }
        pulseReplicator.frame = bounds
        pulseSourceLayer.frame = bounds
        pulseSourceLayer.path = CGPath(ellipseIn: coreRect.insetBy(dx: -3, dy: -3), transform: nil)
        coreLayer.frame = coreRect
        coreMaskLayer.frame = CGRect(origin: .zero, size: coreRect.size)
        coreMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: coreRect.size),
            transform: nil
        )
        plasmaContainerLayer.frame = coreRect
        plasmaMaskLayer.frame = CGRect(origin: .zero, size: coreRect.size)
        plasmaMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: coreRect.size),
            transform: nil
        )
        plasmaMaskLayer.fillColor = NSColor.white.cgColor
        for plasma in plasmaLayers {
            plasma.frame = CGRect(origin: .zero, size: coreRect.size)
        }
        lensLayer.frame = coreRect
        lensMaskLayer.frame = CGRect(origin: .zero, size: coreRect.size)
        lensMaskLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: coreRect.size).insetBy(dx: 2, dy: 2),
            transform: nil
        )
        lensMaskLayer.fillColor = NSColor.white.cgColor
        lensLayer.isHidden = compact
        irisLayer.frame = coreRect.insetBy(dx: coreRect.width * 0.29, dy: coreRect.height * 0.29)
        irisMaskLayer.frame = CGRect(origin: .zero, size: irisLayer.bounds.size)
        irisMaskLayer.path = CGPath(ellipseIn: irisMaskLayer.bounds, transform: nil)
        irisMaskLayer.fillColor = NSColor.white.cgColor
        let pupilSide = max(4.5, coreRect.width * (compact ? 0.16 : 0.13))
        pupilLayer.frame = CGRect(
            x: coreRect.midX - pupilSide / 2,
            y: coreRect.midY - pupilSide / 2,
            width: pupilSide,
            height: pupilSide
        )
        let glintSide = max(7, coreRect.width * 0.19)
        glintLayer.frame = CGRect(
            x: coreRect.minX + coreRect.width * 0.24,
            y: coreRect.maxY - coreRect.height * 0.34,
            width: glintSide,
            height: glintSide
        )
        photonReplicator.frame = bounds
        photonReplicator.instanceCount = compact ? 12 : 24
        photonReplicator.instanceTransform = CATransform3DMakeRotation(
            (2 * .pi) / Double(photonReplicator.instanceCount), 0, 0, 1
        )
        photonSourceLayer.frame = bounds
        let photonSide = compact ? 1.1 : 1.75
        photonSourceLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - photonSide / 2,
                y: innerRect.maxY + (compact ? 1 : 5),
                width: photonSide,
                height: photonSide
            ),
            transform: nil
        )
        photonReplicator.isHidden = compact
        sparkReplicator.frame = bounds
        sparkReplicator.instanceTransform = CATransform3DMakeRotation(
            (2 * .pi) / Double(sparkReplicator.instanceCount),
            0, 0, 1
        )
        let sparkSide = compact ? 1.6 : 2.2
        sparkSourceLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - sparkSide / 2,
                y: innerRect.maxY - sparkSide / 2,
                width: sparkSide,
                height: sparkSide
            ),
            transform: nil
        )
        titleLayer.isHidden = compact
        stateLayer.isHidden = compact
        detailLayer.isHidden = compact
        titleLayer.frame = CGRect(x: 24, y: 25, width: bounds.width - 48, height: 18)
        stateLayer.frame = CGRect(x: 24, y: 11, width: bounds.width - 48, height: 14)
        detailLayer.frame = CGRect(x: 24, y: 0, width: bounds.width - 48, height: 11)
        CATransaction.commit()
    }

    private func signalAmplitude(for state: JarvisPresenceState) -> CGFloat {
        switch state {
        case .standby: return 1.8
        case .awakening: return 3.2
        case .listening: return 7.0
        case .thinking: return 4.6
        case .speaking: return 8.5
        case .capturing: return 3.8
        case .rejected: return 9.0
        }
    }

    private func organicRingPath(
        in rect: CGRect,
        amplitude: CGFloat,
        lobes: Int,
        phase: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        let points = 120
        for index in 0...points {
            let angle = CGFloat(index) / CGFloat(points) * 2 * .pi
            let primary = sin(angle * CGFloat(lobes) + phase)
            let secondary = sin(angle * CGFloat(lobes + 3) - phase * 1.7) * 0.38
            let radius = baseRadius + amplitude * (primary + secondary)
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func radialSignalPath(
        around rect: CGRect,
        amplitude: CGFloat,
        phase: CGFloat = 0.7,
        frequency: CGFloat = 11.0
    ) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        let points = 96
        for index in 0...points {
            let angle = CGFloat(index) / CGFloat(points) * 2 * .pi
            let carrier = abs(sin(angle * frequency + phase))
            let envelope = 0.28 + 0.72 * abs(sin(angle * 2.5 - phase * 0.57))
            let radius = baseRadius + amplitude * carrier * envelope
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    func configure(for state: JarvisPresenceState) {
        currentState = state
        let color = state.color
        let secondary = state.secondaryColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
        )
        spectralHaloLayer.colors = [
            NSColor.clear.cgColor,
            color.withAlphaComponent(0.08).cgColor,
            secondary.withAlphaComponent(0.22).cgColor,
            color.withAlphaComponent(0.05).cgColor,
            NSColor.clear.cgColor,
        ]
        coronaSourceLayer.strokeColor = secondary.withAlphaComponent(0.64).cgColor
        outerRingLayer.strokeColor = color.withAlphaComponent(0.96).cgColor
        middleRingLayer.strokeColor = secondary.withAlphaComponent(0.66).cgColor
        innerRingLayer.strokeColor = NSColor.white.withAlphaComponent(0.86).cgColor
        fieldLayer.strokeColor = color.withAlphaComponent(0.34).cgColor
        horizonLayer.strokeColor = secondary.withAlphaComponent(0.20).cgColor
        for (index, arc) in dataArcLayers.enumerated() {
            arc.strokeColor = (index.isMultiple(of: 2) ? color : secondary)
                .withAlphaComponent(0.72 - CGFloat(index) * 0.08).cgColor
        }
        energyRibbonLayers[0].strokeColor = color.withAlphaComponent(0.72).cgColor
        energyRibbonLayers[1].strokeColor = secondary.withAlphaComponent(0.62).cgColor
        neuralFilamentLayer.strokeColor = color.withAlphaComponent(0.72).cgColor
        neuralEchoLayer.strokeColor = secondary.withAlphaComponent(0.46).cgColor
        waveformLayer.strokeColor = secondary.withAlphaComponent(0.62).cgColor
        waveformEchoLayer.strokeColor = color.withAlphaComponent(0.42).cgColor
        for (index, ring) in gyroscopeRingLayers.enumerated() {
            ring.strokeColor = (index == 1 ? secondary : color)
                .withAlphaComponent(0.54 - CGFloat(index) * 0.07).cgColor
        }
        pulseSourceLayer.strokeColor = color.withAlphaComponent(0.70).cgColor
        photonSourceLayer.fillColor = secondary.withAlphaComponent(0.94).cgColor
        sparkSourceLayer.fillColor = color.withAlphaComponent(0.90).cgColor
        stateLayer.string = "\(state.activityGlyph)  \(state.label)  //  LOCAL"
        stateLayer.foregroundColor = color.withAlphaComponent(0.96).cgColor
        detailLayer.string = state == .capturing
            ? "LOCAL  •  PRIVATE  •  VISUAL"
            : state == .rejected
            ? "OWNER LOCK  •  SECURE"
            : "LOCAL  •  PRIVATE  •  AWARE"
        coreLayer.colors = [
            NSColor.white.cgColor,
            color.cgColor,
            secondary.withAlphaComponent(0.90).cgColor,
            NSColor.black.withAlphaComponent(0.96).cgColor,
        ]
        coreLayer.locations = [0.0, 0.18, 0.58, 1.0]
        let accents = [
            color, secondary, NSColor.systemCyan, NSColor.systemPurple,
            NSColor.systemBlue, NSColor.systemPink,
        ]
        for (index, plasma) in plasmaLayers.enumerated() {
            plasma.colors = [
                NSColor.white.withAlphaComponent(index == 0 ? 0.86 : 0.18).cgColor,
                accents[index].withAlphaComponent(index == 0 ? 0.74 : 0.58).cgColor,
                NSColor.clear.cgColor,
            ]
        }
        lensLayer.colors = [
            NSColor.clear.cgColor,
            color.withAlphaComponent(0.44).cgColor,
            NSColor.clear.cgColor,
            secondary.withAlphaComponent(0.36).cgColor,
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.16).cgColor,
            NSColor.clear.cgColor,
        ]
        irisLayer.colors = [
            NSColor.white.withAlphaComponent(0.94).cgColor,
            color.withAlphaComponent(0.34).cgColor,
            NSColor.clear.cgColor,
        ]
        pupilLayer.colors = [
            NSColor.white.withAlphaComponent(0.98).cgColor,
            secondary.withAlphaComponent(0.58).cgColor,
            color.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor,
        ]
        pupilLayer.locations = [0.0, 0.20, 0.58, 1.0]
        let compact = state.isCompact
        spectralHaloLayer.opacity = compact ? 0.54 : 0.90
        coronaReplicator.opacity = compact ? 0.0 : 0.72
        outerRingLayer.opacity = compact ? 0.58 : 0.82
        middleRingLayer.opacity = compact ? 0.46 : 0.68
        innerRingLayer.opacity = compact ? 0.48 : 0.72
        fieldLayer.opacity = compact ? 0.30 : 0.72
        horizonLayer.opacity = compact ? 0.30 : 0.58
        for (index, arc) in dataArcLayers.enumerated() {
            arc.opacity = compact ? 0.0 : Float(0.72 - Double(index) * 0.08)
        }
        energyRibbonLayers[0].opacity = compact ? 0.0 : 0.84
        energyRibbonLayers[1].opacity = compact ? 0.0 : 0.64
        neuralFilamentLayer.opacity = compact ? 0.42 : 0.86
        neuralEchoLayer.opacity = compact ? 0.0 : 0.58
        waveformLayer.opacity = compact
            ? 0.34
            : (state == .listening || state == .speaking ? 0.94 : 0.68)
        waveformEchoLayer.opacity = compact
            ? 0.0
            : (state == .listening || state == .speaking ? 0.72 : 0.42)
        sweepLayer.opacity = compact ? 0.26 : (state == .capturing ? 1.0 : 0.56)
        for (index, container) in gyroscopeContainers.enumerated() {
            container.opacity = compact ? 0.0 : Float(0.54 - Double(index) * 0.08)
        }
        lensLayer.opacity = compact ? 0.0 : 0.76
        pupilLayer.opacity = compact ? 0.74 : 0.96
        photonReplicator.opacity = compact ? 0.0 : 0.82
        sparkReplicator.opacity = compact ? 0.52 : 0.88
        backdropLayer.opacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? 1.0 : (compact ? 0.82 : 1.0)
        needsLayout = true
        CATransaction.commit()
        startAnimations()
    }

    func playEntrance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let burst = CAKeyframeAnimation(keyPath: "transform.scale")
        burst.values = [0.24, 0.72, 1.19, 0.94, 1.035, 1.0]
        burst.keyTimes = [0.0, 0.24, 0.56, 0.73, 0.88, 1.0]
        burst.duration = 0.72
        burst.timingFunctions = (0..<5).map { _ in
            CAMediaTimingFunction(name: .easeOut)
        }
        let materialize = CAKeyframeAnimation(keyPath: "opacity")
        materialize.values = [0.0, 0.22, 1.0, 0.88, 1.0]
        materialize.keyTimes = [0.0, 0.18, 0.54, 0.76, 1.0]
        materialize.duration = burst.duration
        let entrance = CAAnimationGroup()
        entrance.animations = [burst, materialize]
        entrance.duration = burst.duration
        layer?.add(entrance, forKey: "jarvis.presenceEntrance")

        let ringReveal = CABasicAnimation(keyPath: "strokeEnd")
        ringReveal.fromValue = 0.0
        ringReveal.toValue = 1.0
        ringReveal.duration = 0.66
        ringReveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        outerRingLayer.add(ringReveal, forKey: "jarvis.presenceEntranceRing")
        for (index, ribbon) in energyRibbonLayers.enumerated() {
            let reveal = ringReveal.copy() as! CABasicAnimation
            reveal.duration = 0.46 + Double(index) * 0.14
            ribbon.add(reveal, forKey: "jarvis.presenceEntranceRibbon\(index)")
        }

        let coreIgnition = CAKeyframeAnimation(keyPath: "transform.scale")
        coreIgnition.values = [0.12, 1.38, 0.82, 1.08, 1.0]
        coreIgnition.keyTimes = [0.0, 0.42, 0.64, 0.84, 1.0]
        coreIgnition.duration = 0.78
        coreIgnition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        plasmaContainerLayer.add(coreIgnition, forKey: "jarvis.presenceEntranceCore")

        let coronaIgnition = CAKeyframeAnimation(keyPath: "transform.scale")
        coronaIgnition.values = [0.18, 1.48, 0.86, 1.0]
        coronaIgnition.keyTimes = [0.0, 0.52, 0.78, 1.0]
        coronaIgnition.duration = 0.68
        coronaIgnition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        coronaReplicator.add(coronaIgnition, forKey: "jarvis.presenceEntranceCorona")
    }

    func playStandbySettle() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let settle = CAKeyframeAnimation(keyPath: "transform.scale")
        settle.values = [1.10, 0.90, 1.045, 0.985, 1.0]
        settle.keyTimes = [0.0, 0.31, 0.58, 0.80, 1.0]
        settle.duration = 0.62
        settle.timingFunctions = (0..<4).map { _ in
            CAMediaTimingFunction(name: .easeInEaseOut)
        }
        layer?.add(settle, forKey: "jarvis.presenceStandbySettle")

        let afterglow = CAKeyframeAnimation(keyPath: "opacity")
        afterglow.values = [1.0, 0.26, 0.78, 0.54]
        afterglow.keyTimes = [0.0, 0.34, 0.69, 1.0]
        afterglow.duration = 0.76
        spectralHaloLayer.add(afterglow, forKey: "jarvis.presenceStandbyAfterglow")
    }

    private func startAnimations() {
        stopAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            coreLayer.opacity = 1
            plasmaContainerLayer.opacity = 0.86
            return
        }
        func spin(_ layer: CALayer, duration: Double, clockwise: Bool, key: String) {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.byValue = (clockwise ? 1.0 : -1.0) * Double.pi * 2.0
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: key)
        }
        func march(_ layer: CAShapeLayer, duration: Double, reverse: Bool, key: String) {
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.byValue = reverse ? -28.0 : 28.0
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: key)
        }
        let compact = currentState.isCompact
        let cinematicMotion = !compact && allowsCinematicMotion
        let activityRate: Double
        switch currentState {
        case .thinking: activityRate = 0.68
        case .speaking: activityRate = 0.60
        case .listening: activityRate = 0.78
        case .capturing: activityRate = 0.72
        case .rejected: activityRate = 1.20
        case .awakening, .standby: activityRate = 1.0
        }
        spin(
            outerRingLayer,
            duration: compact ? 13.0 : currentState == .thinking ? 2.25 : 5.4,
            clockwise: true,
            key: "jarvis.presenceOuter"
        )
        spin(
            middleRingLayer,
            duration: compact ? 9.5 : currentState == .thinking ? 1.55 : 3.7,
            clockwise: false,
            key: "jarvis.presenceMiddle"
        )
        spin(
            innerRingLayer,
            duration: compact ? 7.8 : currentState == .listening ? 1.30 : 2.35,
            clockwise: true,
            key: "jarvis.presenceInner"
        )
        spin(
            sweepLayer,
            duration: compact ? 11.0 : currentState == .capturing ? 0.90 : 3.1,
            clockwise: true,
            key: "jarvis.presenceSweep"
        )
        spin(
            neuralFilamentLayer,
            duration: compact ? 8.2 : currentState == .thinking ? 1.85 : 4.1,
            clockwise: false,
            key: "jarvis.presenceNeural"
        )
        spin(
            sparkReplicator,
            duration: compact ? 10.5 : currentState == .thinking ? 2.65 : 5.8,
            clockwise: true,
            key: "jarvis.presenceSparks"
        )
        march(
            neuralFilamentLayer,
            duration: compact ? 4.8 : 1.8 * activityRate,
            reverse: true,
            key: "jarvis.presenceNeuralFlow"
        )

        let haloScale = CAKeyframeAnimation(keyPath: "transform.scale")
        haloScale.values = compact
            ? [0.94, 1.06, 0.98, 1.035, 0.94]
            : [0.88, 1.12, 0.97, 1.08, 0.88]
        haloScale.keyTimes = [0.0, 0.24, 0.51, 0.77, 1.0]
        haloScale.duration = compact ? 4.2 : 2.1 * activityRate
        haloScale.repeatCount = .infinity
        haloScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let haloOpacity = CAKeyframeAnimation(keyPath: "opacity")
        haloOpacity.values = compact ? [0.34, 0.62, 0.44, 0.56, 0.34] : [0.48, 0.96, 0.62, 0.86, 0.48]
        haloOpacity.keyTimes = haloScale.keyTimes
        haloOpacity.duration = haloScale.duration
        haloOpacity.repeatCount = .infinity
        let haloGroup = CAAnimationGroup()
        haloGroup.animations = [haloScale, haloOpacity]
        haloGroup.duration = haloScale.duration
        haloGroup.repeatCount = .infinity
        spectralHaloLayer.add(haloGroup, forKey: "jarvis.presenceSpectralHalo")

        if cinematicMotion {
            // Precomputed, point-compatible paths let Core Animation morph the
            // membrane and signal geometry on the render server. No display
            // link or per-frame Swift work is involved.
            let activeCenter = CGPoint(x: bounds.midX, y: bounds.midY + 15)
            let activeDiameter = min(170, min(bounds.width - 40, bounds.height - 68))
            let activeOuterRect = CGRect(
                x: activeCenter.x - activeDiameter / 2,
                y: activeCenter.y - activeDiameter / 2,
                width: activeDiameter,
                height: activeDiameter
            )
            let activeMiddleRect = activeOuterRect.insetBy(
                dx: activeDiameter * 0.085,
                dy: activeDiameter * 0.085
            )
            let activeInnerRect = activeOuterRect.insetBy(
                dx: activeDiameter * 0.205,
                dy: activeDiameter * 0.205
            )
            for (index, ribbon) in energyRibbonLayers.enumerated() {
                let rect = activeMiddleRect.insetBy(
                    dx: index == 0 ? 1 : 8,
                    dy: index == 0 ? 1 : 8
                )
                let baseAmplitude: CGFloat = index == 0 ? 5.7 : 3.8
                let lobes = index == 0
                    ? (currentState == .thinking ? 17 : 11)
                    : (currentState == .speaking ? 19 : 14)
                let morph = CAKeyframeAnimation(keyPath: "path")
                morph.values = [
                    organicRingPath(in: rect, amplitude: baseAmplitude * 0.72, lobes: lobes, phase: -1.18),
                    organicRingPath(in: rect, amplitude: baseAmplitude * 1.18, lobes: lobes, phase: 0.34),
                    organicRingPath(in: rect, amplitude: baseAmplitude * 0.88, lobes: lobes, phase: 1.72),
                    organicRingPath(in: rect, amplitude: baseAmplitude * 1.08, lobes: lobes, phase: 2.88),
                    organicRingPath(in: rect, amplitude: baseAmplitude * 0.72, lobes: lobes, phase: -1.18),
                ]
                morph.keyTimes = [0.0, 0.21, 0.49, 0.76, 1.0]
                morph.duration = (2.35 + Double(index) * 0.71) * activityRate
                morph.repeatCount = .infinity
                morph.timingFunctions = (0..<4).map { _ in
                    CAMediaTimingFunction(name: .easeInEaseOut)
                }
                ribbon.add(morph, forKey: "jarvis.presenceRibbonMorph\(index)")
            }

            let neuralMorph = CAKeyframeAnimation(keyPath: "path")
            let neuralRect = activeMiddleRect.insetBy(dx: 5, dy: 5)
            let neuralLobes = currentState == .thinking ? 13 : 9
            neuralMorph.values = [
                organicRingPath(in: neuralRect, amplitude: 2.6, lobes: neuralLobes, phase: -0.8),
                organicRingPath(in: neuralRect, amplitude: 4.4, lobes: neuralLobes, phase: 0.9),
                organicRingPath(in: neuralRect, amplitude: 3.1, lobes: neuralLobes, phase: 2.4),
                organicRingPath(in: neuralRect, amplitude: 2.6, lobes: neuralLobes, phase: -0.8),
            ]
            neuralMorph.keyTimes = [0.0, 0.32, 0.68, 1.0]
            neuralMorph.duration = 2.72 * activityRate
            neuralMorph.repeatCount = .infinity
            neuralMorph.timingFunctions = (0..<3).map { _ in
                CAMediaTimingFunction(name: .easeInEaseOut)
            }
            neuralFilamentLayer.add(neuralMorph, forKey: "jarvis.presenceNeuralMorph")

            let signalRect = activeInnerRect.insetBy(dx: -5, dy: -5)
            let waveMorph = CAKeyframeAnimation(keyPath: "path")
            let waveAmplitude = signalAmplitude(for: currentState)
            waveMorph.values = [
                radialSignalPath(around: signalRect, amplitude: waveAmplitude * 0.58, phase: -0.4, frequency: 11),
                radialSignalPath(around: signalRect, amplitude: waveAmplitude * 1.16, phase: 1.2, frequency: 11),
                radialSignalPath(around: signalRect, amplitude: waveAmplitude * 0.78, phase: 2.7, frequency: 11),
                radialSignalPath(around: signalRect, amplitude: waveAmplitude * 1.04, phase: 4.1, frequency: 11),
                radialSignalPath(around: signalRect, amplitude: waveAmplitude * 0.58, phase: -0.4, frequency: 11),
            ]
            waveMorph.keyTimes = [0.0, 0.19, 0.48, 0.74, 1.0]
            waveMorph.duration = (currentState == .speaking ? 0.74 : 1.42) * activityRate
            waveMorph.repeatCount = .infinity
            waveMorph.timingFunctions = (0..<4).map { _ in
                CAMediaTimingFunction(name: .easeInEaseOut)
            }
            waveformLayer.add(waveMorph, forKey: "jarvis.presenceWaveMorph")

            spin(
                coronaReplicator,
                duration: 13.0 * activityRate,
                clockwise: currentState != .thinking,
                key: "jarvis.presenceCorona"
            )
            spin(
                photonReplicator,
                duration: 2.85 * activityRate,
                clockwise: true,
                key: "jarvis.presencePhotons"
            )
            spin(
                lensLayer,
                duration: 1.92 * activityRate,
                clockwise: currentState != .capturing,
                key: "jarvis.presenceLens"
            )
            for (index, ribbon) in energyRibbonLayers.enumerated() {
                spin(
                    ribbon,
                    duration: (index == 0 ? 4.8 : 3.35) * activityRate,
                    clockwise: index == 0,
                    key: "jarvis.presenceRibbonSpin\(index)"
                )
                if ribbon.lineDashPattern != nil {
                    march(
                        ribbon,
                        duration: 1.35 * activityRate,
                        reverse: index.isMultiple(of: 2),
                        key: "jarvis.presenceRibbonFlow\(index)"
                    )
                }
                let ribbonBreath = CAKeyframeAnimation(keyPath: "opacity")
                ribbonBreath.values = index == 0
                    ? [0.42, 0.92, 0.58, 0.84, 0.42]
                    : [0.30, 0.76, 0.44, 0.68, 0.30]
                ribbonBreath.keyTimes = [0.0, 0.19, 0.48, 0.74, 1.0]
                ribbonBreath.duration = (1.7 + Double(index) * 0.43) * activityRate
                ribbonBreath.repeatCount = .infinity
                ribbon.add(ribbonBreath, forKey: "jarvis.presenceRibbonBreath\(index)")
            }
            for (index, arc) in dataArcLayers.enumerated() {
                spin(
                    arc,
                    duration: (2.4 + Double(index) * 0.77) * activityRate,
                    clockwise: index.isMultiple(of: 2),
                    key: "jarvis.presenceDataArcSpin\(index)"
                )
                march(
                    arc,
                    duration: (1.15 + Double(index) * 0.24) * activityRate,
                    reverse: !index.isMultiple(of: 2),
                    key: "jarvis.presenceDataArcFlow\(index)"
                )
                let trace = CAKeyframeAnimation(keyPath: "strokeEnd")
                let base = min(0.90, 0.36 + Double(index) * 0.12)
                trace.values = [base, min(0.98, base + 0.22), max(0.24, base - 0.09), base]
                trace.keyTimes = [0.0, 0.31, 0.67, 1.0]
                trace.duration = (1.45 + Double(index) * 0.31) * activityRate
                trace.repeatCount = .infinity
                trace.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                arc.add(trace, forKey: "jarvis.presenceDataArcTrace\(index)")
            }
            for (index, ring) in gyroscopeRingLayers.enumerated() {
                spin(
                    ring,
                    duration: (1.85 + Double(index) * 0.81) * activityRate,
                    clockwise: !index.isMultiple(of: 2),
                    key: "jarvis.presenceGyroscope\(index)"
                )
                march(
                    ring,
                    duration: (1.22 + Double(index) * 0.26) * activityRate,
                    reverse: index.isMultiple(of: 2),
                    key: "jarvis.presenceGyroscopeFlow\(index)"
                )
            }
            march(
                neuralEchoLayer,
                duration: 1.25 * activityRate,
                reverse: false,
                key: "jarvis.presenceNeuralEchoFlow"
            )
            march(
                waveformEchoLayer,
                duration: 0.92 * activityRate,
                reverse: true,
                key: "jarvis.presenceWaveformEchoFlow"
            )

            let coronaShimmer = CAKeyframeAnimation(keyPath: "opacity")
            coronaShimmer.values = [0.18, 0.82, 0.34, 0.68, 0.18]
            coronaShimmer.keyTimes = [0.0, 0.17, 0.48, 0.76, 1.0]
            coronaShimmer.duration = 1.62 * activityRate
            coronaShimmer.repeatCount = .infinity
            coronaSourceLayer.add(coronaShimmer, forKey: "jarvis.presenceCoronaShimmer")

            let photonPulse = CAKeyframeAnimation(keyPath: "transform.scale")
            photonPulse.values = [0.42, 1.55, 0.72, 1.18, 0.42]
            photonPulse.keyTimes = [0.0, 0.16, 0.47, 0.73, 1.0]
            photonPulse.duration = 0.94 * activityRate
            photonPulse.repeatCount = .infinity
            photonSourceLayer.add(photonPulse, forKey: "jarvis.presencePhotonPulse")

            let pupilOrbit = CAKeyframeAnimation(keyPath: "transform.translation")
            pupilOrbit.values = [
                NSValue(point: CGPoint(x: -2.4, y: 1.2)),
                NSValue(point: CGPoint(x: 1.1, y: 2.8)),
                NSValue(point: CGPoint(x: 2.7, y: -0.7)),
                NSValue(point: CGPoint(x: -0.8, y: -2.4)),
                NSValue(point: CGPoint(x: -2.4, y: 1.2)),
            ]
            pupilOrbit.keyTimes = [0.0, 0.22, 0.51, 0.79, 1.0]
            pupilOrbit.duration = 3.4 * activityRate
            pupilOrbit.repeatCount = .infinity
            pupilOrbit.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pupilLayer.add(pupilOrbit, forKey: "jarvis.presencePupilOrbit")
        }

        for (index, plasma) in plasmaLayers.enumerated() {
            let drift = CAKeyframeAnimation(keyPath: "transform.translation")
            let reach = compact ? 2.0 : 4.5 + Double(index) * 0.55
            drift.values = [
                NSValue(point: CGPoint(x: -reach, y: reach * 0.25)),
                NSValue(point: CGPoint(x: reach * 0.58, y: reach)),
                NSValue(point: CGPoint(x: reach, y: -reach * 0.45)),
                NSValue(point: CGPoint(x: -reach * 0.28, y: -reach)),
                NSValue(point: CGPoint(x: -reach, y: reach * 0.25)),
            ]
            drift.keyTimes = [0.0, 0.23, 0.54, 0.79, 1.0]
            let morph = CAKeyframeAnimation(keyPath: "transform.scale")
            morph.values = [0.86, 1.14, 0.96, 1.09, 0.86]
            morph.keyTimes = [0.0, 0.27, 0.51, 0.76, 1.0]
            let group = CAAnimationGroup()
            group.animations = [drift, morph]
            group.duration = (compact ? 5.8 : 3.2) + Double(index) * 0.83
            group.repeatCount = .infinity
            group.autoreverses = index.isMultiple(of: 2)
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            plasma.add(group, forKey: "jarvis.presencePlasma\(index)")
        }

        let breathe = CAKeyframeAnimation(keyPath: "transform.scale")
        breathe.values = compact
            ? [0.97, 1.035, 0.99, 1.02, 0.97]
            : currentState == .speaking
            ? [0.91, 1.11, 0.96, 1.07, 0.91]
            : [0.94, 1.075, 0.98, 1.04, 0.94]
        breathe.keyTimes = [0.0, 0.21, 0.49, 0.76, 1.0]
        breathe.duration = compact ? 3.15 : currentState == .speaking ? 0.66 : 1.48
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreLayer.add(breathe, forKey: "jarvis.presenceCore")
        plasmaContainerLayer.add(breathe.copy() as! CAAnimation, forKey: "jarvis.presencePlasmaBreathe")

        let iris = CAKeyframeAnimation(keyPath: "opacity")
        iris.values = compact ? [0.52, 0.82, 0.58] : [0.64, 1.0, 0.74, 0.94, 0.64]
        iris.keyTimes = compact ? [0.0, 0.46, 1.0] : [0.0, 0.20, 0.48, 0.75, 1.0]
        iris.duration = compact ? 2.8 : currentState == .speaking ? 0.58 : 1.16
        iris.repeatCount = .infinity
        iris.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        irisLayer.add(iris, forKey: "jarvis.presenceIris")

        let pupilFocus = CAKeyframeAnimation(keyPath: "transform.scale")
        pupilFocus.values = compact
            ? [0.76, 1.18, 0.88, 1.06, 0.76]
            : [0.58, 1.36, 0.82, 1.18, 0.58]
        pupilFocus.keyTimes = [0.0, 0.18, 0.50, 0.76, 1.0]
        pupilFocus.duration = compact ? 3.6 : 1.24 * activityRate
        pupilFocus.repeatCount = .infinity
        pupilFocus.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pupilLayer.add(pupilFocus, forKey: "jarvis.presencePupilFocus")

        let innerTrace = CAKeyframeAnimation(keyPath: "strokeEnd")
        innerTrace.values = compact ? [0.62, 0.78, 0.68, 0.62] : [0.42, 0.91, 0.64, 0.82, 0.42]
        innerTrace.keyTimes = compact ? [0.0, 0.36, 0.72, 1.0] : [0.0, 0.18, 0.47, 0.73, 1.0]
        innerTrace.duration = compact ? 4.1 : 1.28 * activityRate
        innerTrace.repeatCount = .infinity
        innerTrace.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        innerRingLayer.add(innerTrace, forKey: "jarvis.presenceInnerTrace")

        let signal = CAKeyframeAnimation(keyPath: "transform.scale")
        signal.values = compact ? [0.99, 1.015, 0.99] : [0.96, 1.045, 0.985, 1.06, 0.96]
        signal.keyTimes = compact ? [0.0, 0.5, 1.0] : [0.0, 0.18, 0.48, 0.72, 1.0]
        signal.duration = compact ? 3.0 : currentState == .speaking ? 0.52 : 1.05
        signal.repeatCount = .infinity
        waveformLayer.add(signal, forKey: "jarvis.presenceSignal")

        if cinematicMotion {
            let waveTrace = CAKeyframeAnimation(keyPath: "strokeEnd")
            waveTrace.values = [0.36, 1.0, 0.72, 0.94, 0.36]
            waveTrace.keyTimes = [0.0, 0.22, 0.48, 0.76, 1.0]
            waveTrace.duration = 1.08 * activityRate
            waveTrace.repeatCount = .infinity
            waveTrace.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            waveformLayer.add(waveTrace, forKey: "jarvis.presenceWaveTrace")

            let plasmaPrecession = CABasicAnimation(keyPath: "transform.rotation.z")
            plasmaPrecession.byValue = Double.pi * 2.0
            plasmaPrecession.duration = 8.4 * activityRate
            plasmaPrecession.repeatCount = .infinity
            plasmaPrecession.timingFunction = CAMediaTimingFunction(name: .linear)
            plasmaContainerLayer.add(
                plasmaPrecession,
                forKey: "jarvis.presencePlasmaPrecession"
            )
        }

        let pulseScale = CABasicAnimation(keyPath: "transform.scale")
        pulseScale.fromValue = compact ? 0.92 : 0.88
        pulseScale.toValue = compact ? 1.90 : 2.75
        pulseScale.duration = compact ? 3.2 : 1.45
        pulseScale.repeatCount = .infinity
        pulseScale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let pulseFade = CABasicAnimation(keyPath: "opacity")
        pulseFade.fromValue = compact ? 0.22 : 0.70
        pulseFade.toValue = 0.0
        pulseFade.duration = pulseScale.duration
        pulseFade.repeatCount = .infinity
        let group = CAAnimationGroup()
        group.animations = [pulseScale, pulseFade]
        group.duration = pulseScale.duration
        group.repeatCount = .infinity
        pulseSourceLayer.add(group, forKey: "jarvis.presencePulse")

        let textPulse = CABasicAnimation(keyPath: "opacity")
        textPulse.fromValue = 0.58
        textPulse.toValue = 1.0
        textPulse.duration = 0.75
        textPulse.autoreverses = true
        textPulse.repeatCount = .infinity
        stateLayer.add(textPulse, forKey: "jarvis.presenceText")

        let glint = CAKeyframeAnimation(keyPath: "opacity")
        glint.values = [0.30, 0.92, 0.46, 0.78, 0.30]
        glint.keyTimes = [0.0, 0.18, 0.48, 0.73, 1.0]
        glint.duration = compact ? 2.4 : 1.05
        glint.repeatCount = .infinity
        glintLayer.add(glint, forKey: "jarvis.presenceGlint")

        if cinematicMotion {
            let glintDrift = CAKeyframeAnimation(keyPath: "transform.translation")
            glintDrift.values = [
                NSValue(point: CGPoint(x: -1.5, y: 0.5)),
                NSValue(point: CGPoint(x: 2.8, y: 1.4)),
                NSValue(point: CGPoint(x: 0.8, y: -2.0)),
                NSValue(point: CGPoint(x: -1.5, y: 0.5)),
            ]
            glintDrift.keyTimes = [0.0, 0.36, 0.72, 1.0]
            glintDrift.duration = 2.65 * activityRate
            glintDrift.repeatCount = .infinity
            glintDrift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glintLayer.add(glintDrift, forKey: "jarvis.presenceGlintDrift")
        }

        if currentState == .rejected {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -5, 4, -3, 2, 0]
            shake.duration = 0.34
            shake.repeatCount = 2
            layer?.add(shake, forKey: "jarvis.presenceRejected")
        }
    }

    func stopAnimations() {
        for item in [
            layer, spectralHaloLayer, coronaReplicator, coronaSourceLayer,
            outerRingLayer, middleRingLayer, innerRingLayer,
            neuralFilamentLayer, neuralEchoLayer, waveformLayer, waveformEchoLayer,
            sweepLayer, coreLayer, plasmaContainerLayer, lensLayer, irisLayer,
            pupilLayer, glintLayer, photonReplicator, photonSourceLayer,
            sparkReplicator, pulseSourceLayer, stateLayer,
        ] {
            item?.removeAllAnimations()
        }
        for arc in dataArcLayers { arc.removeAllAnimations() }
        for ribbon in energyRibbonLayers { ribbon.removeAllAnimations() }
        for container in gyroscopeContainers { container.removeAllAnimations() }
        for ring in gyroscopeRingLayers { ring.removeAllAnimations() }
        for plasma in plasmaLayers { plasma.removeAllAnimations() }
    }
}

private final class JarvisPresenceHUDController {
    private var panel: NSPanel?
    private var presenceView: JarvisPresenceView?
    private var ambientEnabled = false
    private var transitionGeneration = 0
    private var currentState: JarvisPresenceState = .standby
    private weak var lastScreen: NSScreen?

    func setAmbientEnabled(_ enabled: Bool, on screen: NSScreen? = nil) {
        DispatchQueue.main.async {
            self.ambientEnabled = enabled
            self.transitionGeneration += 1
            if enabled {
                self.present(.standby, on: screen, playEntrance: true)
            } else {
                self.hideImmediately()
            }
        }
    }

    func show(_ state: JarvisPresenceState, on screen: NSScreen? = nil) {
        DispatchQueue.main.async {
            self.transitionGeneration += 1
            self.present(state, on: screen, playEntrance: true)
        }
    }

    func dismiss(after delay: Double = 0.0) {
        DispatchQueue.main.async {
            self.transitionGeneration += 1
            let generation = self.transitionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
                guard generation == self.transitionGeneration else { return }
                if self.ambientEnabled {
                    self.present(.standby, on: self.lastScreen, playEntrance: false)
                } else {
                    self.fadeOutAndHide(generation: generation)
                }
            }
        }
    }

    func preview(on screen: NSScreen? = nil) {
        DispatchQueue.main.async {
            self.transitionGeneration += 1
            let generation = self.transitionGeneration
            let states: [JarvisPresenceState] = [
                .awakening, .listening, .thinking, .capturing, .speaking,
            ]
            for (index, state) in states.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.15) {
                    guard generation == self.transitionGeneration else { return }
                    self.present(state, on: screen, playEntrance: index == 0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(states.count) * 1.15) {
                guard generation == self.transitionGeneration else { return }
                if self.ambientEnabled {
                    self.present(.standby, on: screen, playEntrance: false)
                } else {
                    self.fadeOutAndHide(generation: generation)
                }
            }
        }
    }

    func refreshAccessibility(on screen: NSScreen? = nil) {
        DispatchQueue.main.async {
            guard self.panel?.isVisible == true || self.ambientEnabled else { return }
            self.transitionGeneration += 1
            self.present(self.currentState, on: screen, playEntrance: false)
        }
    }

    /// Fully hides the surface for sleep, Siri handoff, or emergency stop.
    /// Normal voice completion should use dismiss(), which returns to standby.
    func hide() {
        DispatchQueue.main.async {
            self.transitionGeneration += 1
            self.fadeOutAndHide(generation: self.transitionGeneration)
        }
    }

    private func present(
        _ state: JarvisPresenceState,
        on screen: NSScreen?,
        playEntrance: Bool
    ) {
        let previousState = currentState
        currentState = state
        let panel = self.panel ?? self.makePanel()
        guard let view = self.presenceView else { return }
        let wasVisible = panel.isVisible
        let targetScreen = screen ?? lastScreen ?? NSScreen.main ?? NSScreen.screens.first
        lastScreen = targetScreen
        let side = state.panelSide
        let margin: CGFloat = state.isCompact ? 18 : 24
        if let visible = targetScreen?.visibleFrame {
            panel.setFrame(
                NSRect(
                    x: visible.maxX - side - margin,
                    y: visible.maxY - side - margin,
                    width: side,
                    height: side
                ),
                display: true
            )
        } else {
            panel.setContentSize(NSSize(width: side, height: side))
        }
        view.configure(for: state)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        let targetAlpha: CGFloat = state.isCompact ? 0.78 : 1.0
        if wasVisible {
            panel.alphaValue = targetAlpha
            if playEntrance && !state.isCompact { view.playEntrance() }
            if state.isCompact && !previousState.isCompact { view.playStandbySettle() }
            return
        }
        panel.alphaValue = 0
        if playEntrance { view.playEntrance() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = state.isCompact ? 0.30 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = targetAlpha
        }
    }

    private func fadeOutAndHide(generation: Int) {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            guard generation == self.transitionGeneration else { return }
            self.hideImmediately()
        })
    }

    private func hideImmediately() {
        presenceView?.stopAnimations()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 112, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        let view = JarvisPresenceView(frame: panel.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
        self.presenceView = view
        return panel
    }
}

private func presenceState(named rawValue: String?) -> JarvisPresenceState {
    switch rawValue?.lowercased() {
    case "standby", "awake": return .standby
    case "awakening", "online": return .awakening
    case "listening": return .listening
    case "speaking", "responding": return .speaking
    case "capturing", "observing": return .capturing
    case "rejected": return .rejected
    default: return .thinking
    }
}

private func renderPresencePreview(state: JarvisPresenceState = .thinking) throws -> URL {
    let side = state.panelSide
    let view = JarvisPresenceView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.configure(for: state)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 81,
            userInfo: [NSLocalizedDescriptionKey: "The preview bitmap could not be created."]
        )
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 82,
            userInfo: [NSLocalizedDescriptionKey: "The preview PNG could not be encoded."]
        )
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-presence-preview-\(state.label.lowercased()).png")
    try data.write(to: url, options: .atomic)
    return url
}

final class JarvisMenuController: NSObject, NSApplicationDelegate, NSMenuDelegate,
    AVSpeechSynthesizerDelegate, NSSoundDelegate {
    private var statusItem: NSStatusItem!
    private var serverProcess: Process?
    private let voiceRecorder = PushToTalkRecorder()
    private let wakeWordListener = WakeWordListener()
    private let ownerVoiceRuntime = OwnerVoiceRuntime()
    private let presenceHUD = JarvisPresenceHUDController()
    private var ownerEnrollmentListener: WakeWordListener?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var neuralSpeechSound: NSSound?
    private var neuralSpeechURL: URL?
    private var neuralSpeechBusy = false
    private var talkMenuItem: NSMenuItem?
    private var voiceShortcutMenuItem: NSMenuItem?
    private var wakeWordMenuItem: NSMenuItem?
    private var healthMenuItem: NSMenuItem?
    private var ownerVoiceMenuItem: NSMenuItem?
    private var autonomousActionsMenuItem: NSMenuItem?
    private var spokenResponsesMenuItem: NSMenuItem?
    private var persistentPresenceMenuItem: NSMenuItem?
    private var conversationFollowupsMenuItem: NSMenuItem?
    private var awarenessMenuItem: NSMenuItem?
    private var deepReasoningMenuItem: NSMenuItem?
    private var startAtLoginMenuItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var voiceTargetApplication: NSRunningApplication?
    private var pendingAutonomousActions: [[String: Any]]?
    private var autonomousPreviewAlert: NSAlert?
    private var autonomousActionTimer: Timer?
    private var voiceFlowBusy = false
    private var liveVoiceDiagnosticActive = false
    private var siriHandoffActive = false
    private var followUpPending = false
    private var wakeListeningVisualActive = false
    private var systemSleeping = false
    private var captureInProgress = false
    private var lastOwnerVoiceSimilarity = 0.0
    private var lastOwnerVoiceThreshold = ownerVoiceMaximumEffectiveThreshold
    private var lastOwnerVoiceReferenceMatches = 0
    private var lastOwnerVoicePitchMatch = false
    private var wakeWordLastError: String?
    private var preferredMicrophoneListenerInstalled = false
    private var lastRazerConnected: Bool?
    private var wakeHealthGeneration = 0
    private var ownerEnrollmentSamples: [URL] = []
    private var ownerEnrollmentGeneration = 0
    private var accessibilitySceneCache: CachedAccessibilityScene?
    private let dashboardToken = UUID().uuidString + UUID().uuidString
    private let detachedProcessLock = NSLock()
    private var detachedProcesses: [Process] = []
    private var lastAwarenessRefreshAt = Date.distantPast

    private var dashboardURL: URL {
        var components = URLComponents(string: "http://127.0.0.1:8765/")!
        components.queryItems = [URLQueryItem(name: "token", value: dashboardToken)]
        return components.url!
    }

    private var projectPath: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jarvis/Data/install_path")
        guard let raw = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jarvis/Code").standardizedFileURL
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        return candidate.path == expected.path ? expected.path : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        speechSynthesizer.delegate = self
        installPreferredMicrophoneListener()
        lastRazerConnected = preferredRazerMicrophoneID() != nil
        makeRazerMicrophoneDefaultInput()
        prewarmModernSpeechRecognition()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleTradingViewReviewDiagnosticRequest(_:)),
            name: tradingViewReviewDiagnosticNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runTradingViewNYFibDiagnostic),
            name: tradingViewNYFibDiagnosticNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActiveWindowCaptureRequest(_:)),
            name: activeWindowCaptureRequestNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runLiveVoiceDiagnostic),
            name: liveVoiceDiagnosticNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(previewJarvisPresence),
            name: presencePreviewNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleTestSpokenResponse(_:)),
            name: testSpokenResponseNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIntentTalk),
            name: intentTalkNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIntentAsk(_:)),
            name: intentAskNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIntentStatus),
            name: intentStatusNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIntentPrivateMode(_:)),
            name: intentPrivateModeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleIntentRemember(_:)),
            name: intentRememberNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.hexagongrid.fill",
                accessibilityDescription: "Jarvis"
            )
            button.toolTip = "Jarvis"
        }
        statusItem.menu = makeMenu()
        startServerIfNeeded()
        refreshOwnerVoiceLockStatus()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAccessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        runDetached(["emit-event", "login", "--payload-json", "{}"])
        if voiceShortcutEnabled {
            registerGlobalVoiceShortcut(showFailure: false)
        }
        refreshMenuState()
        refreshAwarenessMenuState(force: true)
        scheduleWakeHealthCheck()
        presenceHUD.setAmbientEnabled(
            persistentPresenceEnabled,
            on: statusItem.button?.window?.screen
        )
        if wakeWordEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.authorizeWakeWordIfNeeded()
            }
        }

        if runLiveVoiceDiagnosticAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.runLiveVoiceDiagnostic()
            }
        }

        if !CGPreflightScreenCaptureAccess() {
            logVoiceDiagnostic("screen_capture_unavailable automatic_prompt_suppressed=true")
        }
        if !AXIsProcessTrusted() || !CGPreflightPostEventAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                _ = CGRequestPostEventAccess()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        autonomousActionTimer?.invalidate()
        autonomousActionTimer = nil
        pendingAutonomousActions = nil
        detachedProcessLock.lock()
        let detached = detachedProcesses
        detachedProcesses.removeAll()
        detachedProcessLock.unlock()
        for process in detached where process.isRunning { process.terminate() }
        wakeHealthGeneration += 1
        wakeWordListener.stop()
        ownerEnrollmentListener?.stop()
        cleanupOwnerEnrollmentSamples()
        voiceRecorder.cancel()
        unregisterGlobalVoiceShortcut()
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
    }

    @objc private func handleActiveWindowCaptureRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestID = userInfo["request_id"] as? String,
              !requestID.isEmpty,
              let rawDestination = userInfo["destination"] as? String,
              let destination = allowedCaptureDestination(rawDestination),
              let rawResponse = userInfo["response_path"] as? String,
              let responseURL = allowedCaptureResponseURL(rawResponse) else {
            return
        }
        setCaptureInProgress(true)
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { self.setCaptureInProgress(false) }
            }
            let response: [String: Any]
            do {
                let requestedApplication = userInfo["target_app"] as? String
                var payload: [String: Any]
                if let requestedApplication, !requestedApplication.isEmpty {
                    payload = try captureNamedApplicationWindowImage(
                        named: requestedApplication,
                        to: destination.path
                    )
                } else {
                    payload = try captureActiveWindowImage(to: destination.path)
                }
                payload["request_id"] = requestID
                payload["capture_engine"] = "Jarvis.app/ScreenCaptureKit/running-process"
                payload["via_running_app"] = true
                response = payload
                logVoiceDiagnostic("capture_ipc_completed request=\(requestID.prefix(8))")
            } catch {
                response = [
                    "ok": false,
                    "request_id": requestID,
                    "error": error.localizedDescription,
                ]
                logVoiceDiagnostic("capture_ipc_failed request=\(requestID.prefix(8))")
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: response,
                options: [.sortedKeys]
            ) else { return }
            try? data.write(to: responseURL, options: .atomic)
        }
    }

    @objc private func runLiveVoiceDiagnostic() {
        guard !voiceFlowBusy, voiceRecorder.state == .idle else {
            logVoiceDiagnostic("live_voice_diagnostic_rejected busy=true")
            return
        }
        liveVoiceDiagnosticActive = true
        logVoiceDiagnostic("live_voice_diagnostic_started")
        startVoiceRecording(playReadySound: true)
    }

    @objc private func handleIntentTalk() {
        guard !voiceFlowBusy, voiceRecorder.state == .idle else { return }
        startVoiceRecording(playReadySound: true)
    }

    @objc private func handleIntentAsk(_ notification: Notification) {
        guard let request = notification.userInfo?["request"] as? String,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        prepareTranscriptPreview(request)
    }

    @objc private func handleIntentStatus() {
        showJarvisStatus()
    }

    @objc private func handleIntentPrivateMode(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }
        runDetached(["private-mode", enabled ? "on" : "off"])
    }

    @objc private func handleIntentRemember(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        runDetached(["remember", text, "--privacy", "private"])
    }

    private var voiceShortcutEnabled: Bool {
        if UserDefaults.standard.object(forKey: voiceShortcutDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: voiceShortcutDefaultsKey)
    }

    private var wakeWordEnabled: Bool {
        if UserDefaults.standard.object(forKey: wakeWordDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: wakeWordDefaultsKey)
    }

    private var ownerVoiceLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: ownerVoiceLockDefaultsKey)
    }

    private func refreshOwnerVoiceLockStatus() {
        runPythonCapture(["owner-voice-status"]) { [weak self] result in
            guard let self, case .success(let data) = result,
                  let payload = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let enabled = payload["enabled"] as? Bool else { return }
            UserDefaults.standard.set(enabled, forKey: ownerVoiceLockDefaultsKey)
            if enabled {
                self.ownerVoiceRuntime.preload()
            } else {
                self.ownerVoiceRuntime.unload()
            }
            self.refreshMenuState()
        }
    }

    private var autonomousStandardActionsEnabled: Bool {
        if UserDefaults.standard.object(forKey: autonomousActionsDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autonomousActionsDefaultsKey)
    }

    private var spokenResponsesEnabled: Bool {
        if UserDefaults.standard.object(forKey: spokenResponsesDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: spokenResponsesDefaultsKey)
    }

    private var isJarvisSpeaking: Bool {
        neuralSpeechBusy
            || neuralSpeechSound?.isPlaying == true
            || speechSynthesizer.isSpeaking
    }

    private var conversationFollowupsEnabled: Bool {
        if UserDefaults.standard.object(forKey: conversationFollowupsDefaultsKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: conversationFollowupsDefaultsKey)
    }

    /// Keeps a compact, low-energy orb visible in the top-right corner while
    /// Jarvis is available. Active voice states expand the same surface instead
    /// of spawning a second animation, so visual ownership remains unambiguous.
    private var persistentPresenceEnabled: Bool {
        if UserDefaults.standard.object(forKey: persistentPresenceDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: persistentPresenceDefaultsKey)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        talkMenuItem = item("Talk to Jarvis (⌃Space)", action: #selector(toggleTalk), key: "")
        menu.addItem(talkMenuItem!)
        menu.addItem(item(
            "Emergency Stop All Actions (⌘.)",
            action: #selector(emergencyStop),
            key: "."
        ))
        voiceShortcutMenuItem = item(
            "Enable Global Voice Shortcut",
            action: #selector(toggleVoiceShortcut),
            key: ""
        )
        menu.addItem(voiceShortcutMenuItem!)
        wakeWordMenuItem = item(
            "Enable “Jarvis” Wake Word",
            action: #selector(toggleWakeWord),
            key: ""
        )
        menu.addItem(wakeWordMenuItem!)
        healthMenuItem = item(
            "Jarvis Status…",
            action: #selector(showJarvisStatus),
            key: ""
        )
        menu.addItem(healthMenuItem!)
        menu.addItem(item(
            "Teach Jarvis a Pronunciation…",
            action: #selector(teachJarvisPronunciation),
            key: ""
        ))
        ownerVoiceMenuItem = item(
            "Owner Voice Lock…",
            action: #selector(manageOwnerVoiceLock),
            key: ""
        )
        menu.addItem(ownerVoiceMenuItem!)
        autonomousActionsMenuItem = item(
            "Autonomous Standard Actions",
            action: #selector(toggleAutonomousActions),
            key: ""
        )
        menu.addItem(autonomousActionsMenuItem!)
        spokenResponsesMenuItem = item(
            "Spoken Responses",
            action: #selector(toggleSpokenResponses),
            key: ""
        )
        menu.addItem(spokenResponsesMenuItem!)
        persistentPresenceMenuItem = item(
            "Keep Jarvis Presence Visible",
            action: #selector(togglePersistentPresence),
            key: ""
        )
        menu.addItem(persistentPresenceMenuItem!)
        menu.addItem(item(
            "Preview Jarvis Presence",
            action: #selector(previewJarvisPresence),
            key: ""
        ))
        menu.addItem(item(
            "Test Jarvis Voice…",
            action: #selector(testJarvisVoice),
            key: ""
        ))
        conversationFollowupsMenuItem = item(
            "Automatically Record Follow-ups",
            action: #selector(toggleConversationFollowups),
            key: ""
        )
        menu.addItem(conversationFollowupsMenuItem!)
        awarenessMenuItem = item(
            "Awareness: Loading…",
            action: #selector(showAwarenessStatus),
            key: ""
        )
        menu.addItem(awarenessMenuItem!)
        deepReasoningMenuItem = item(
            "Deep Conversational Reasoning (4B)",
            action: #selector(toggleDeepConversation),
            key: ""
        )
        menu.addItem(deepReasoningMenuItem!)
        menu.addItem(item(
            "Remember Strategy Detail…",
            action: #selector(rememberStrategyDetail),
            key: ""
        ))
        menu.addItem(.separator())
        menu.addItem(item("Ask Jarvis Automatically", action: #selector(askJarvis), key: "j"))
        menu.addItem(item("Send To Jarvis Chat", action: #selector(sendToChat), key: ""))
        menu.addItem(item("Send To Jarvis Work", action: #selector(sendToWork), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard", action: #selector(openDashboard), key: "d"))
        menu.addItem(item("Read Active Window", action: #selector(readScreen), key: "r"))
        menu.addItem(item("Export Memory", action: #selector(exportMemory), key: ""))
        menu.addItem(.separator())
        startAtLoginMenuItem = item(
            "Start Jarvis at Login",
            action: #selector(toggleStartAtLogin),
            key: ""
        )
        menu.addItem(startAtLoginMenuItem!)
        menu.addItem(item(
            "Check Accessibility Permission",
            action: #selector(checkAccessibilityPermission),
            key: ""
        ))
        menu.addItem(item("Check Screen Permission", action: #selector(checkScreenPermission), key: ""))
        menu.addItem(item("Restart Core", action: #selector(restartCore), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Jarvis", action: #selector(quitJarvis), key: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
        refreshAwarenessMenuState()
    }

    @objc private func teachJarvisPronunciation() {
        let heardLabel = NSTextField(labelWithString: "What Jarvis hears")
        let heardField = NSTextField(string: "")
        heardField.placeholderString = "Example: trading few"
        let intendedLabel = NSTextField(labelWithString: "What you mean")
        let intendedField = NSTextField(string: "")
        intendedField.placeholderString = "Example: TradingView"
        let stack = NSStackView(
            views: [heardLabel, heardField, intendedLabel, intendedField]
        )
        stack.orientation = .vertical
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 112)

        let alert = NSAlert()
        alert.messageText = "Teach Jarvis a pronunciation"
        alert.informativeText = (
            "This stays on this Mac. Jarvis will bias Apple speech recognition "
            + "toward the correct phrase and apply the correction before interpreting commands."
        )
        alert.alertStyle = .informational
        alert.accessoryView = stack
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let heard = heardField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intended = intendedField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty,
              !intended.isEmpty,
              heard.count <= 120,
              intended.count <= 120 else {
            showAlert(
                title: "Pronunciation not saved",
                message: "Enter both phrases using 120 characters or fewer."
            )
            return
        }
        runPythonCapture([
            "add-vocabulary", heard,
            "--replacement", intended,
            "--category", "learned_voice",
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.showAlert(
                    title: "Pronunciation learned",
                    message: "Jarvis will use “\(intended)” when it hears “\(heard)”."
                )
                logVoiceDiagnostic("voice_vocabulary_learned")
            case .failure(let error):
                self.showAlert(
                    title: "Pronunciation not saved",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func authenticateOwnerChange(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        ) else {
            showAlert(
                title: "Touch ID required",
                message: error?.localizedDescription
                    ?? "Set up Touch ID in System Settings before changing Owner Voice Lock."
            )
            completion(false)
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    @objc private func manageOwnerVoiceLock() {
        let alert = NSAlert()
        alert.messageText = ownerVoiceLockEnabled
            ? "Owner Voice Lock is on" : "Set up Owner Voice Lock"
        alert.informativeText = (
            "Jarvis uses a compact on-device speaker model plus your normal pitch range. "
            + "The profile stays in the macOS Keychain; raw enrollment recordings are deleted. "
            + "Voice never replaces Touch ID for credentials."
        )
        alert.alertStyle = .informational
        if ownerVoiceLockEnabled {
            alert.addButton(withTitle: "Test My Voice")
            alert.addButton(withTitle: "Re-enroll")
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if !ownerVoiceLockEnabled {
            guard response == .alertFirstButtonReturn else { return }
            authenticateOwnerChange(reason: "Enroll your private Jarvis owner voice.") {
                [weak self] authenticated in
                if authenticated { self?.startOwnerVoiceEnrollment() }
            }
            return
        }
        switch response {
        case .alertFirstButtonReturn:
            startOwnerVoiceTest()
        case .alertSecondButtonReturn:
            authenticateOwnerChange(reason: "Replace your Jarvis owner voice profile.") {
                [weak self] authenticated in
                if authenticated { self?.startOwnerVoiceEnrollment() }
            }
        case .alertThirdButtonReturn:
            authenticateOwnerChange(reason: "Disable Jarvis Owner Voice Lock.") {
                [weak self] authenticated in
                guard authenticated, let self else { return }
                self.runPythonCapture(["owner-voice-disable"]) { result in
                    switch result {
                    case .success:
                        UserDefaults.standard.set(false, forKey: ownerVoiceLockDefaultsKey)
                        self.ownerVoiceRuntime.unload()
                        logVoiceDiagnostic("owner_voice_disabled touch_id=true")
                        self.refreshMenuState()
                        self.showAlert(
                            title: "Owner Voice Lock disabled",
                            message: "The Keychain voice profile was deleted."
                        )
                    case .failure(let error):
                        self.showAlert(
                            title: "Owner Voice Lock was not changed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        default:
            break
        }
    }

    private func cleanupOwnerEnrollmentSamples() {
        for url in ownerEnrollmentSamples {
            try? FileManager.default.removeItem(at: url)
        }
        ownerEnrollmentSamples.removeAll()
    }

    private func finishOwnerVoiceSetupFlow() {
        ownerEnrollmentGeneration += 1
        ownerEnrollmentListener?.stop()
        ownerEnrollmentListener = nil
        cleanupOwnerEnrollmentSamples()
        voiceFlowBusy = false
        wakeListeningVisualActive = false
        refreshMenuState()
        startWakeWordListenerIfPossible()
    }

    private func captureOwnerVoiceSample(
        prompt: String,
        sampleNumber: Int,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Owner voice sample \(sampleNumber) of 5"
        alert.informativeText = (
            "Use your normal speaking voice and usual Razer microphone distance.\n\n"
            + "Say: “\(prompt)”"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Listening")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(.failure(NSError(
                domain: jarvisBundleIdentifier,
                code: 130,
                userInfo: [NSLocalizedDescriptionKey: "Owner voice setup was canceled."]
            )))
            return
        }

        let listener = WakeWordListener()
        ownerEnrollmentListener = listener
        ownerEnrollmentGeneration += 1
        let generation = ownerEnrollmentGeneration
        var completed = false
        let finish: (Result<URL, Error>) -> Void = { [weak self] result in
            guard let self, !completed,
                  self.ownerEnrollmentGeneration == generation else { return }
            completed = true
            self.ownerEnrollmentListener?.stop()
            self.ownerEnrollmentListener = nil
            self.wakeListeningVisualActive = false
            self.refreshMenuState()
            completion(result)
        }
        do {
            try listener.start(
                onDetected: { sampleURL in
                    guard let sampleURL else {
                        finish(.failure(NSError(
                            domain: jarvisBundleIdentifier,
                            code: 131,
                            userInfo: [NSLocalizedDescriptionKey: "No usable voice sample was captured."]
                        )))
                        return
                    }
                    finish(.success(sampleURL))
                },
                onWakeWordHeard: { [weak self] in
                    self?.wakeListeningVisualActive = true
                    self?.updateVoiceStatusIcon()
                },
                onSiriWakeWord: {
                    finish(.failure(NSError(
                        domain: jarvisBundleIdentifier,
                        code: 132,
                        userInfo: [NSLocalizedDescriptionKey: "Say the displayed Jarvis phrase."]
                    )))
                },
                onCommandDetected: { _, sampleURL in
                    guard let sampleURL else {
                        finish(.failure(NSError(
                            domain: jarvisBundleIdentifier,
                            code: 133,
                            userInfo: [NSLocalizedDescriptionKey: "No usable voice sample was captured."]
                        )))
                        return
                    }
                    finish(.success(sampleURL))
                },
                onError: { error in finish(.failure(error)) }
            )
            NSSound(named: "Tink")?.play()
            wakeListeningVisualActive = true
            refreshMenuState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 18.0) {
                finish(.failure(NSError(
                    domain: jarvisBundleIdentifier,
                    code: 134,
                    userInfo: [NSLocalizedDescriptionKey: "No Jarvis phrase was heard in time."]
                )))
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func startOwnerVoiceEnrollment() {
        guard !voiceFlowBusy else { return }
        voiceFlowBusy = true
        wakeWordListener.stop()
        cleanupOwnerEnrollmentSamples()
        refreshMenuState()

        func capture(index: Int) {
            guard index < ownerVoiceEnrollmentPrompts.count else {
                let arguments = ["owner-voice-enroll"]
                    + ownerEnrollmentSamples.map(\.path)
                runPythonCapture(arguments) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        UserDefaults.standard.set(true, forKey: ownerVoiceLockDefaultsKey)
                        self.ownerVoiceRuntime.reload()
                        logVoiceDiagnostic(
                            "owner_voice_enrolled samples=\(self.ownerEnrollmentSamples.count)"
                        )
                        self.showAlert(
                            title: "Owner Voice Lock is on",
                            message: (
                                "Jarvis now requires your enrolled regular voice for wake words "
                                + "and voice commands. Touch ID remains required for credentials."
                            )
                        )
                    case .failure(let error):
                        self.showAlert(
                            title: "Owner voice was not enrolled",
                            message: error.localizedDescription
                        )
                    }
                    self.finishOwnerVoiceSetupFlow()
                }
                return
            }
            captureOwnerVoiceSample(
                prompt: ownerVoiceEnrollmentPrompts[index],
                sampleNumber: index + 1
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.ownerEnrollmentSamples.append(url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        capture(index: index + 1)
                    }
                case .failure(let error):
                    self.showAlert(
                        title: "Owner voice setup stopped",
                        message: error.localizedDescription
                    )
                    self.finishOwnerVoiceSetupFlow()
                }
            }
        }
        capture(index: 0)
    }

    private func startOwnerVoiceTest() {
        guard !voiceFlowBusy else { return }
        voiceFlowBusy = true
        wakeWordListener.stop()
        refreshMenuState()
        let prompt = ownerVoiceEnrollmentPrompts.randomElement()
            ?? ownerVoiceEnrollmentPrompts[0]
        captureOwnerVoiceSample(
            prompt: prompt,
            sampleNumber: 1
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showAlert(
                    title: "Owner voice test stopped",
                    message: error.localizedDescription
                )
                self.finishOwnerVoiceSetupFlow()
            case .success(let url):
                self.ownerEnrollmentSamples = [url]
                self.ownerVoiceRuntime.verify(audioURL: url) { verifyResult in
                    switch verifyResult {
                    case .failure(let error):
                        self.showAlert(
                            title: "Owner voice test failed",
                            message: error.localizedDescription
                        )
                    case .success(let match):
                        let accepted = match.accepted
                        let score = String(
                            format: "%.1f%%",
                            match.similarity * 100
                        )
                        self.showAlert(
                            title: accepted
                                ? "Owner voice accepted" : "Voice rejected",
                            message: accepted
                                ? "Your regular voice passed. Match score: \(score)."
                                : "This sample did not pass the owner voice and style checks."
                        )
                        logVoiceDiagnostic(
                            "owner_voice_manual_test accepted=\(accepted)"
                        )
                    }
                    self.finishOwnerVoiceSetupFlow()
                }
            }
        }
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        return value
    }

    private func refreshMenuState() {
        if voiceFlowBusy && voiceRecorder.state == .idle {
            talkMenuItem?.title = "Reviewing Voice Request…"
            talkMenuItem?.isEnabled = false
        } else {
        switch voiceRecorder.state {
        case .idle:
            talkMenuItem?.title = "Talk to Jarvis (⌃Space)"
            talkMenuItem?.isEnabled = true
        case .authorizing:
            talkMenuItem?.title = "Cancel Voice Request (⌃Space)"
            talkMenuItem?.isEnabled = true
        case .recording:
            talkMenuItem?.title = "Stop and Review Recording (⌃Space)"
            talkMenuItem?.isEnabled = true
        case .transcribing:
            talkMenuItem?.title = "Transcribing…"
            talkMenuItem?.isEnabled = false
        }
        }
        voiceShortcutMenuItem?.state = voiceShortcutEnabled ? .on : .off
        wakeWordMenuItem?.state = wakeWordEnabled ? .on : .off
        ownerVoiceMenuItem?.state = ownerVoiceLockEnabled ? .on : .off
        ownerVoiceMenuItem?.title = ownerVoiceLockEnabled
            ? "Owner Voice Lock: On…" : "Owner Voice Lock…"
        if wakeWordEnabled, let error = wakeWordLastError, !error.isEmpty {
            wakeWordMenuItem?.title = "Enable “Jarvis” Wake Word (Unavailable)"
        } else {
            wakeWordMenuItem?.title = "Enable “Jarvis” Wake Word"
        }
        if !wakeWordEnabled {
            healthMenuItem?.title = "Status: Wake Word Off"
        } else if wakeWordListener.isListening {
            let microphone = defaultInputDeviceName()
            healthMenuItem?.title = microphone.lowercased().contains("razer")
                ? "Status: Ready • Razer"
                : "Status: Ready • \(microphone)"
        } else if wakeWordLastError != nil {
            healthMenuItem?.title = "Status: Voice Needs Attention…"
        } else {
            healthMenuItem?.title = "Status: Voice Starting…"
        }
        autonomousActionsMenuItem?.state = autonomousStandardActionsEnabled ? .on : .off
        spokenResponsesMenuItem?.state = spokenResponsesEnabled ? .on : .off
        persistentPresenceMenuItem?.state = persistentPresenceEnabled ? .on : .off
        conversationFollowupsMenuItem?.state = conversationFollowupsEnabled ? .on : .off

        let loginStatus = SMAppService.mainApp.status
        switch loginStatus {
        case .enabled:
            startAtLoginMenuItem?.state = .on
            startAtLoginMenuItem?.title = "Start Jarvis at Login"
        case .requiresApproval:
            startAtLoginMenuItem?.state = .mixed
            startAtLoginMenuItem?.title = "Start Jarvis at Login (Approval Needed)"
        default:
            startAtLoginMenuItem?.state = .off
            startAtLoginMenuItem?.title = "Start Jarvis at Login"
        }
        updateVoiceStatusIcon()
    }

    private func updateVoiceStatusIcon() {
        guard let button = statusItem.button else { return }
        if captureInProgress {
            button.image = NSImage(
                systemSymbolName: "viewfinder.circle.fill",
                accessibilityDescription: "Jarvis is capturing a requested window"
            )
            button.contentTintColor = .systemOrange
            button.toolTip = "Jarvis is capturing the requested window"
            return
        }
        let activeListeningVisual = wakeListeningVisualActive
            || voiceRecorder.state == .authorizing
            || voiceRecorder.state == .recording
        if activeListeningVisual {
            button.image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "Jarvis is listening"
            )
            button.contentTintColor = .systemBlue
            button.setAccessibilityLabel("Jarvis is listening")
            button.toolTip = voiceRecorder.state == .authorizing
                ? "Jarvis is preparing to listen"
                : "Jarvis is listening — press Control-Space to stop"
            return
        }

        switch voiceRecorder.state {
        case .idle:
            if wakeWordListener.isListening {
                button.image = NSImage(
                    systemSymbolName: "ear.fill",
                    accessibilityDescription: "Listening for Jarvis wake word"
                )
                button.contentTintColor = .systemGreen
                button.toolTip = "Say Jarvis or press Control-Space"
            } else {
                button.image = NSImage(
                    systemSymbolName: "circle.hexagongrid.fill",
                    accessibilityDescription: "Jarvis"
                )
                button.contentTintColor = nil
                button.toolTip = "Jarvis"
            }
        case .authorizing:
            break
        case .recording:
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Recording voice command"
            )
            button.contentTintColor = .systemRed
            button.toolTip = "Jarvis is recording — press Control-Space to stop"
        case .transcribing:
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Transcribing voice command"
            )
            button.contentTintColor = .systemBlue
            button.toolTip = "Jarvis is transcribing"
        }
    }

    private func setCaptureInProgress(_ active: Bool) {
        if Thread.isMainThread {
            captureInProgress = active
            if active {
                presenceHUD.show(.capturing, on: statusItem.button?.window?.screen)
            } else if !voiceFlowBusy && !isJarvisSpeaking {
                presenceHUD.dismiss(after: 0.15)
            }
            updateVoiceStatusIcon()
        } else {
            DispatchQueue.main.async { self.setCaptureInProgress(active) }
        }
    }

    @objc private func emergencyStop() {
        clearPendingAutonomousAction()
        followUpPending = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        stopNeuralSpeech()
        voiceRecorder.cancel()
        wakeWordListener.stop()
        wakeListeningVisualActive = false
        voiceFlowBusy = false
        liveVoiceDiagnosticActive = false
        captureInProgress = false
        presenceHUD.dismiss()
        detachedProcessLock.lock()
        let processes = detachedProcesses
        detachedProcesses.removeAll()
        detachedProcessLock.unlock()
        for process in processes where process.isRunning { process.terminate() }
        logVoiceDiagnostic("emergency_stop")
        refreshMenuState()
        if wakeWordEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.authorizeWakeWordIfNeeded()
            }
        }
    }

    @objc private func toggleVoiceShortcut() {
        let enable = !voiceShortcutEnabled
        UserDefaults.standard.set(enable, forKey: voiceShortcutDefaultsKey)
        if enable {
            registerGlobalVoiceShortcut(showFailure: true)
        } else {
            unregisterGlobalVoiceShortcut()
        }
        refreshMenuState()
    }

    @objc private func toggleWakeWord() {
        let enable = !wakeWordEnabled
        UserDefaults.standard.set(enable, forKey: wakeWordDefaultsKey)
        wakeWordLastError = nil
        if enable {
            authorizeWakeWordIfNeeded()
            if !wakeWordListener.isListening, let error = wakeWordLastError {
                showAlert(title: "Wake word unavailable", message: error)
            }
        } else {
            wakeWordListener.stop()
            wakeListeningVisualActive = false
        }
        refreshMenuState()
    }

    @objc private func showJarvisStatus() {
        let speechStatus: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechStatus = "Authorized"
        case .denied:
            speechStatus = "Denied"
        case .restricted:
            speechStatus = "Restricted"
        case .notDetermined:
            speechStatus = "Waiting for approval"
        @unknown default:
            speechStatus = "Unknown"
        }

        let microphoneStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = "Authorized"
        case .denied:
            microphoneStatus = "Denied"
        case .restricted:
            microphoneStatus = "Restricted"
        case .notDetermined:
            microphoneStatus = "Waiting for approval"
        @unknown default:
            microphoneStatus = "Unknown"
        }

        let wakeStatus = !wakeWordEnabled
            ? "Off"
            : (wakeWordListener.isListening ? "Listening" : "Recovering")
        let coreStatus = serverProcess?.isRunning == true ? "Running" : "Recovering"
        let loginStatus = loginItemStatusName(SMAppService.mainApp.status)
        let message = [
            "Wake word: \(wakeStatus)",
            "Input: \(defaultInputDeviceName())",
            "Microphone access: \(microphoneStatus)",
            "Speech recognition: \(speechStatus)",
            "Local core: \(coreStatus)",
            "Start at login: \(loginStatus)",
        ].joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = wakeWordListener.isListening
            ? "Jarvis is ready"
            : "Jarvis voice is recovering"
        alert.informativeText = message
        if wakeWordEnabled {
            alert.addButton(withTitle: "Restart Voice Listener")
        }
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if wakeWordEnabled, response == .alertFirstButtonReturn {
            restartWakeWordListener()
        }
    }

    private func restartWakeWordListener() {
        wakeWordListener.stop()
        wakeListeningVisualActive = false
        wakeWordLastError = nil
        refreshMenuState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.authorizeWakeWordIfNeeded()
            logVoiceDiagnostic("wake_manual_restart")
        }
    }

    private func authorizeWakeWordIfNeeded() {
        guard wakeWordEnabled, !voiceFlowBusy else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            authorizeWakeWordMicrophoneIfNeeded()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized {
                        self.authorizeWakeWordMicrophoneIfNeeded()
                    } else {
                        self.wakeWordLastError = VoiceSessionError.speechDenied.localizedDescription
                        self.refreshMenuState()
                    }
                }
            }
        default:
            wakeWordLastError = VoiceSessionError.speechDenied.localizedDescription
            refreshMenuState()
        }
    }

    private func authorizeWakeWordMicrophoneIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startWakeWordListenerIfPossible()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startWakeWordListenerIfPossible()
                    } else {
                        self.wakeWordLastError = VoiceSessionError.microphoneDenied.localizedDescription
                        self.refreshMenuState()
                    }
                }
            }
        default:
            wakeWordLastError = VoiceSessionError.microphoneDenied.localizedDescription
            refreshMenuState()
        }
    }

    private func startWakeWordListenerIfPossible() {
        makeRazerMicrophoneDefaultInput()
        guard wakeWordEnabled,
              !systemSleeping,
              !voiceFlowBusy,
              !siriHandoffActive,
              !isJarvisSpeaking,
              voiceRecorder.state == .idle,
              !wakeWordListener.isListening else { return }
        do {
            try wakeWordListener.start(
                onDetected: { [weak self] sampleURL in
                    self?.wakeWordDetected(sampleURL: sampleURL)
                },
                onWakeWordHeard: { [weak self] in self?.wakeWordHeard() },
                onSiriWakeWord: { [weak self] in self?.handoffToSiri() },
                onCommandDetected: { [weak self] command, sampleURL in
                    self?.wakeWordCommandDetected(command, sampleURL: sampleURL)
                },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.wakeListeningVisualActive = false
                    self.wakeWordLastError = error.localizedDescription
                    self.refreshMenuState()
                }
            )
            wakeWordLastError = nil
        } catch {
            wakeWordLastError = error.localizedDescription
        }
        refreshMenuState()
    }

    private func scheduleWakeHealthCheck() {
        wakeHealthGeneration += 1
        let generation = wakeHealthGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + wakeHealthCheckIntervalSeconds
        ) { [weak self] in
            guard let self, self.wakeHealthGeneration == generation else { return }
            if self.wakeWordEnabled,
               !self.systemSleeping,
               !self.voiceFlowBusy,
               !self.siriHandoffActive,
               !self.isJarvisSpeaking,
               self.voiceRecorder.state == .idle {
                if self.wakeWordListener.isListening {
                    self.wakeWordListener.maintainHealth()
                } else {
                    self.authorizeWakeWordIfNeeded()
                }
            }
            self.scheduleWakeHealthCheck()
        }
    }

    private func handlePreferredMicrophoneChange() {
        let wasConnected = lastRazerConnected
        let isConnected = preferredRazerMicrophoneID() != nil
        lastRazerConnected = isConnected
        makeRazerMicrophoneDefaultInput()
        wakeWordListener.refreshAudioRoute()
        if let wasConnected, wasConnected != isConnected {
            let event = isConnected
                ? "microphone_connected" : "microphone_disconnected"
            let payload = compactJSONString([
                "device": "Razer Seiren V3 Mini",
                "default_input": defaultInputDeviceName(),
            ])
            runDetached(["emit-event", event, "--payload-json", payload])
        }
    }

    @objc private func handleWorkspaceSleep() {
        systemSleeping = true
        presenceHUD.hide()
        wakeListeningVisualActive = false
        wakeWordListener.stop()
        ownerEnrollmentGeneration += 1
        ownerEnrollmentListener?.stop()
        ownerEnrollmentListener = nil
        cleanupOwnerEnrollmentSamples()
        voiceFlowBusy = false
        if voiceRecorder.state != .idle {
            voiceRecorder.cancel()
        }
        logVoiceDiagnostic("system_sleep voice_pipeline_paused=true")
        refreshMenuState()
    }

    @objc private func handleWorkspaceWake() {
        systemSleeping = false
        presenceHUD.setAmbientEnabled(
            persistentPresenceEnabled,
            on: statusItem.button?.window?.screen
        )
        runDetached(["emit-event", "wake", "--payload-json", "{}"])
        logVoiceDiagnostic("system_wake voice_pipeline_restart_scheduled=true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self, !self.systemSleeping else { return }
            makeRazerMicrophoneDefaultInput()
            self.startWakeWordListenerIfPossible()
        }
    }

    @objc private func handleApplicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication,
              app.bundleIdentifier != jarvisBundleIdentifier else { return }
        let name = app.localizedName ?? "Unknown"
        let event = name.caseInsensitiveCompare("TradingView") == .orderedSame
            ? "tradingview_opened" : "app_launched"
        runDetached([
            "emit-event",
            event,
            "--payload-json",
            compactJSONString([
                "app": name,
                "bundle_id": app.bundleIdentifier ?? "",
            ]),
        ])
    }

    @objc private func handleAccessibilityDisplayOptionsChanged() {
        presenceHUD.refreshAccessibility(on: statusItem.button?.window?.screen)
    }

    @objc private func handleThermalStateChanged() {
        presenceHUD.refreshAccessibility(on: statusItem.button?.window?.screen)
        runDetached([
            "emit-event",
            "thermal",
            "--payload-json",
            compactJSONString(["state": currentThermalStateName()]),
        ])
    }

    @objc private func handlePowerStateChanged() {
        presenceHUD.refreshAccessibility(on: statusItem.button?.window?.screen)
        logVoiceDiagnostic(
            "presence_power_mode low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        )
    }

    private func installPreferredMicrophoneListener() {
        guard !preferredMicrophoneListenerInstalled else { return }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handlePreferredMicrophoneChange()
        }
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handlePreferredMicrophoneChange()
        }
        preferredMicrophoneListenerInstalled = devicesStatus == noErr && defaultStatus == noErr
        if !preferredMicrophoneListenerInstalled {
            logVoiceDiagnostic(
                "preferred_microphone_listener_failed devices=\(devicesStatus) default=\(defaultStatus)"
            )
        }
    }

    private func handoffToSiri() {
        guard !voiceFlowBusy, !siriHandoffActive else { return }
        siriHandoffActive = true
        presenceHUD.hide()
        wakeListeningVisualActive = false
        refreshMenuState()

        let siriURL = URL(fileURLWithPath: "/System/Applications/Siri.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: siriURL,
            configuration: configuration
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    logVoiceDiagnostic(
                        "siri_handoff_failed detail=\(error.localizedDescription)"
                    )
                    self.finishSiriHandoff()
                    return
                }
                self.monitorSiriHandoff(sawSiri: false, attempt: 0)
            }
        }
    }

    private func monitorSiriHandoff(sawSiri: Bool, attempt: Int) {
        guard siriHandoffActive else { return }
        let siriIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "com.apple.siri.launcher"
        let hasSeenSiri = sawSiri || siriIsFrontmost
        if (hasSeenSiri && !siriIsFrontmost) || (!hasSeenSiri && attempt >= 6)
            || attempt >= 60 {
            finishSiriHandoff()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.monitorSiriHandoff(sawSiri: hasSeenSiri, attempt: attempt + 1)
        }
    }

    private func finishSiriHandoff() {
        siriHandoffActive = false
        presenceHUD.setAmbientEnabled(
            persistentPresenceEnabled,
            on: statusItem.button?.window?.screen
        )
        if wakeWordEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startWakeWordListenerIfPossible()
            }
        }
        refreshMenuState()
    }

    private func wakeWordHeard() {
        guard wakeWordEnabled, !voiceFlowBusy, voiceRecorder.state == .idle else { return }
        guard !ownerVoiceLockEnabled else { return }
        wakeListeningVisualActive = true
        presenceHUD.show(.awakening, on: statusItem.button?.window?.screen)
        updateVoiceStatusIcon()
    }

    private func verifyOwnerVoiceSample(
        _ sampleURL: URL?,
        completion: @escaping (Bool) -> Void
    ) {
        guard ownerVoiceLockEnabled else {
            if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
            lastOwnerVoiceSimilarity = 1
            lastOwnerVoiceThreshold = 0
            lastOwnerVoiceReferenceMatches = 0
            lastOwnerVoicePitchMatch = true
            completion(true)
            return
        }
        guard let sampleURL else {
            lastOwnerVoiceSimilarity = 0
            lastOwnerVoiceReferenceMatches = 0
            lastOwnerVoicePitchMatch = false
            logVoiceDiagnostic("owner_voice_rejected reason=missing_sample")
            completion(false)
            return
        }
        ownerVoiceRuntime.verify(audioURL: sampleURL) { result in
            defer { try? FileManager.default.removeItem(at: sampleURL) }
            switch result {
            case .failure(let error):
                self.lastOwnerVoiceSimilarity = 0
                self.lastOwnerVoiceReferenceMatches = 0
                self.lastOwnerVoicePitchMatch = false
                logVoiceDiagnostic(
                    "owner_voice_verification_failed " + errorDiagnostic(error)
                )
                completion(false)
            case .success(let match):
                let accepted = match.accepted
                self.lastOwnerVoiceSimilarity = match.similarity
                self.lastOwnerVoiceThreshold = match.threshold
                self.lastOwnerVoiceReferenceMatches = match.referenceMatches
                self.lastOwnerVoicePitchMatch = match.pitchMatch
                logVoiceDiagnostic(
                    "owner_voice_verification accepted=\(accepted) "
                    + "reason=\(match.reason) "
                    + "score=\(String(format: "%.3f", match.similarity)) "
                    + "threshold=\(String(format: "%.3f", match.threshold)) "
                    + "references=\(match.referenceMatches) "
                    + "pitch_match=\(match.pitchMatch) "
                    + "tier=\(match.matchTier)"
                )
                completion(accepted)
            }
        }
    }

    private func rejectUnverifiedVoice() {
        wakeListeningVisualActive = false
        presenceHUD.show(.rejected, on: statusItem.button?.window?.screen)
        let likelyOwnerNearMiss = lastOwnerVoiceSimilarity >= 0.60
        if likelyOwnerNearMiss && spokenResponsesEnabled {
            logVoiceDiagnostic("owner_voice_near_miss_explained")
            speakJarvisReply(
                "I heard you, but I could not verify your regular voice. Please try once more."
            )
        } else if let sound = NSSound(named: "Basso") {
            sound.volume = 0.12
            sound.play()
        }
        completeVoiceFlow(presenceDismissDelay: 1.25)
    }

    private func wakeWordDetected(sampleURL: URL?) {
        guard wakeWordEnabled, !voiceFlowBusy, voiceRecorder.state == .idle else {
            if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
            startWakeWordListenerIfPossible()
            return
        }
        voiceFlowBusy = true
        wakeWordListener.stop()
        presenceHUD.show(.awakening, on: statusItem.button?.window?.screen)
        // A one-word wake clip is too short for dependable speaker identity,
        // especially when the fallback Mac microphone is across the room.
        // Treat it only as a request to listen. The complete command recording
        // is still owner-verified before Jarvis interprets or performs it.
        if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
        logVoiceDiagnostic("owner_voice_wake_deferred_to_full_command")
        wakeListeningVisualActive = true
        presenceHUD.show(.listening, on: statusItem.button?.window?.screen)
        updateVoiceStatusIcon()
        // Give the wake recognizer time to release Apple's speech service.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startVoiceRecording(playReadySound: true)
        }
    }

    private func wakeWordCommandDetected(_ command: String, sampleURL: URL?) {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wakeWordEnabled,
              !cleaned.isEmpty,
              !voiceFlowBusy,
              voiceRecorder.state == .idle else {
            if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
            startWakeWordListenerIfPossible()
            return
        }
        voiceFlowBusy = true
        wakeWordListener.stop()
        wakeListeningVisualActive = false
        presenceHUD.show(.awakening, on: statusItem.button?.window?.screen)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != jarvisBundleIdentifier {
            voiceTargetApplication = frontmost
        }
        refreshMenuState()
        verifyOwnerVoiceSample(sampleURL) { [weak self] accepted in
            guard let self else { return }
            guard accepted else {
                self.rejectUnverifiedVoice()
                return
            }
            NSSound(named: "Tink")?.play()
            self.presenceHUD.show(.thinking, on: self.statusItem.button?.window?.screen)
            self.prepareTranscriptPreview(cleaned)
        }
    }

    private func completeVoiceFlow(presenceDismissDelay: Double = 0.12) {
        voiceFlowBusy = false
        wakeListeningVisualActive = false
        if followUpPending && conversationFollowupsEnabled && !isJarvisSpeaking {
            followUpPending = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startVoiceRecording(playReadySound: true)
            }
            refreshMenuState()
            return
        }
        if !isJarvisSpeaking && !captureInProgress {
            presenceHUD.dismiss(after: presenceDismissDelay)
        }
        if wakeWordEnabled && !isJarvisSpeaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startWakeWordListenerIfPossible()
            }
        }
        refreshMenuState()
    }

    @objc private func toggleAutonomousActions() {
        UserDefaults.standard.set(
            !autonomousStandardActionsEnabled,
            forKey: autonomousActionsDefaultsKey
        )
        refreshMenuState()
    }

    @objc private func toggleSpokenResponses() {
        let enabled = !spokenResponsesEnabled
        UserDefaults.standard.set(enabled, forKey: spokenResponsesDefaultsKey)
        if !enabled {
            speechSynthesizer.stopSpeaking(at: .immediate)
            stopNeuralSpeech()
        }
        refreshMenuState()
    }

    @objc private func togglePersistentPresence() {
        let enabled = !persistentPresenceEnabled
        UserDefaults.standard.set(enabled, forKey: persistentPresenceDefaultsKey)
        presenceHUD.setAmbientEnabled(enabled, on: statusItem.button?.window?.screen)
        refreshMenuState()
    }

    @objc private func previewJarvisPresence() {
        presenceHUD.preview(on: statusItem.button?.window?.screen)
    }

    @objc private func toggleConversationFollowups() {
        let enabled = !conversationFollowupsEnabled
        UserDefaults.standard.set(enabled, forKey: conversationFollowupsDefaultsKey)
        if !enabled { followUpPending = false }
        refreshMenuState()
    }

    @objc private func toggleDeepConversation() {
        runPythonCapture(["deep-conversation", "toggle"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.lastAwarenessRefreshAt = .distantPast
                self.refreshAwarenessMenuState(force: true)
            case .failure(let error):
                self.showAlert(
                    title: "Could not change reasoning mode",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func refreshAwarenessMenuState(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAwarenessRefreshAt) > 10 else { return }
        lastAwarenessRefreshAt = Date()
        runPythonCapture(["awareness-status"]) { [weak self] result in
            guard let self, case .success(let data) = result,
                  let payload = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { return }
            let turns = payload["short_term_conversation_turns"] as? Int ?? 0
            let strategy = payload["strategy_memory_count"] as? Int ?? 0
            let deep = payload["deep_conversation_enabled"] as? Bool ?? false
            self.awarenessMenuItem?.title =
                "Awareness: \(turns) Turns • \(strategy) Strategy Memories…"
            self.deepReasoningMenuItem?.state = deep ? .on : .off
            self.deepReasoningMenuItem?.title = deep
                ? "Deep Conversational Reasoning: On (4B)"
                : "Deep Conversational Reasoning: Off"
        }
    }

    @objc private func showAwarenessStatus() {
        runPythonCapture(["awareness-status"]) { [weak self] result in
            guard let self else { return }
            guard case .success(let data) = result,
                  let payload = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                self.showAlert(
                    title: "Operational awareness unavailable",
                    message: "Jarvis's local awareness index could not be read."
                )
                return
            }
            let turns = payload["short_term_conversation_turns"] as? Int ?? 0
            let retention = payload["conversation_retention_turns"] as? Int ?? 500
            let intents = payload["tracked_intents"] as? Int ?? 0
            let strategy = payload["strategy_memory_count"] as? Int ?? 0
            let deep = payload["deep_conversation_enabled"] as? Bool ?? false
            let latest = payload["latest_intent"] as? [String: Any]
            let goal = (latest?["inferred_goal"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let alert = NSAlert()
            alert.messageText = "Jarvis Operational Awareness"
            alert.informativeText = [
                "Current objective: \(goal?.isEmpty == false ? goal! : "Standing by")",
                "Local dialogue recall: \(turns) of \(retention) retained turns",
                "Tracked handoffs: \(intents)",
                "Strategy memories: \(strategy)",
                "Conversational brain: \(deep ? "Qwen3.5 4B on demand" : "fast local mode")",
                "Heavy models unload after idle time. Nothing here is presented as sentience.",
            ].joined(separator: "\n")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Dashboard")
            alert.addButton(withTitle: "Clear Dialogue History…")
            alert.addButton(withTitle: "Close")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openDashboard()
            } else if response == .alertSecondButtonReturn {
                self.confirmClearConversationHistory()
            }
        }
    }

    private func confirmClearConversationHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear local dialogue history?"
        alert.informativeText = (
            "This removes remembered conversation turns. Saved strategy and other "
            + "durable memories are not affected."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runPythonCapture(["clear-conversation-history"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.lastAwarenessRefreshAt = .distantPast
                self.refreshAwarenessMenuState(force: true)
            case .failure(let error):
                self.showAlert(
                    title: "Could not clear dialogue history",
                    message: error.localizedDescription
                )
            }
        }
    }

    @objc private func rememberStrategyDetail() {
        let titleLabel = NSTextField(labelWithString: "Short label")
        let titleField = NSTextField(string: "")
        titleField.placeholderString = "Example: New York continuation filter"
        let detailLabel = NSTextField(labelWithString: "What Jarvis should remember")
        let detailField = NSTextField(string: "")
        detailField.placeholderString = "Describe the rule, context, and exceptions."
        let stack = NSStackView(views: [
            titleLabel, titleField, detailLabel, detailField,
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: 112)
        let alert = NSAlert()
        alert.messageText = "Remember a Strategy Detail"
        alert.informativeText = (
            "Jarvis will use this local memory to interpret future analysis requests. "
            + "It will never use it to execute a trade."
        )
        alert.accessoryView = stack
        alert.addButton(withTitle: "Remember")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let detail = detailField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return }
        let title = titleField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        runPythonCapture([
            "remember", detail,
            "--category", "strategy",
            "--title", title.isEmpty ? "Strategy detail" : title,
            "--kind", "procedure",
            "--privacy", "local",
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.lastAwarenessRefreshAt = .distantPast
                self.refreshAwarenessMenuState(force: true)
                self.showAlert(
                    title: "Strategy memory saved",
                    message: "Jarvis will incorporate it into relevant future analysis."
                )
            case .failure(let error):
                self.showAlert(
                    title: "Could not save strategy memory",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func speakJarvisReply(_ text: String) {
        guard spokenResponsesEnabled else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        wakeWordListener.stop()
        stopNeuralSpeech()
        presenceHUD.show(.speaking, on: statusItem.button?.window?.screen)
        neuralSpeechBusy = true
        runPythonCapture(["synthesize-speech", String(cleaned.prefix(800))]) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    guard let payload = try JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                          let path = payload["path"] as? String else {
                        throw NSError(
                            domain: jarvisBundleIdentifier,
                            code: 31,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Jarvis voice returned an invalid audio response."
                            ]
                        )
                    }
                    let url = URL(fileURLWithPath: path)
                    guard self.spokenResponsesEnabled else {
                        self.neuralSpeechBusy = false
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    guard let sound = NSSound(contentsOf: url, byReference: true) else {
                        throw NSError(
                            domain: jarvisBundleIdentifier,
                            code: 32,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Jarvis could not open the generated speech."
                            ]
                        )
                    }
                    self.neuralSpeechURL = url
                    self.neuralSpeechSound = sound
                    sound.delegate = self
                    self.neuralSpeechBusy = false
                    guard sound.play() else {
                        throw NSError(
                            domain: jarvisBundleIdentifier,
                            code: 33,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Jarvis could not play the generated speech."
                            ]
                        )
                    }
                    logVoiceDiagnostic("neural_voice_playback_started")
                } catch {
                    self.neuralSpeechBusy = false
                    self.stopNeuralSpeech()
                    logVoiceDiagnostic(
                        "neural_voice_playback_failed " + errorDiagnostic(error)
                    )
                    self.speakAppleFallback(cleaned)
                }
            case .failure(let error):
                self.neuralSpeechBusy = false
                guard self.spokenResponsesEnabled else { return }
                logVoiceDiagnostic(
                    "neural_voice_generation_failed " + errorDiagnostic(error)
                )
                self.speakAppleFallback(cleaned)
            }
        }
    }

    private func speakAppleFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(800)))
        let britishVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare("en-GB") == .orderedSame
        }
        utterance.voice = britishVoices.first {
            $0.name.localizedCaseInsensitiveContains("Daniel")
                || $0.name.localizedCaseInsensitiveContains("Oliver")
        } ?? britishVoices.first ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = 0.47
        utterance.pitchMultiplier = 0.92
        speechSynthesizer.speak(utterance)
    }

    private func stopNeuralSpeech() {
        let sound = neuralSpeechSound
        neuralSpeechSound = nil
        sound?.delegate = nil
        sound?.stop()
        if let url = neuralSpeechURL {
            try? FileManager.default.removeItem(at: url)
        }
        neuralSpeechURL = nil
        neuralSpeechBusy = false
    }

    private func finishSpokenReply() {
        if !captureInProgress {
            presenceHUD.dismiss(after: 0.15)
        }
        if followUpPending && conversationFollowupsEnabled && !voiceFlowBusy {
            followUpPending = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startVoiceRecording(playReadySound: true)
            }
            return
        }
        if wakeWordEnabled && !voiceFlowBusy && !siriHandoffActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startWakeWordListenerIfPossible()
            }
        }
    }

    @objc private func testJarvisVoice() {
        speakJarvisReply(
            "Good evening, the owner. Jarvis is online, your strategy is ready, "
                + "and all systems are operating normally."
        )
    }

    @objc private func handleTestSpokenResponse(_ notification: Notification) {
        testJarvisVoice()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard sound === neuralSpeechSound else { return }
        logVoiceDiagnostic("neural_voice_playback_finished completed=\(flag)")
        stopNeuralSpeech()
        finishSpokenReply()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishSpokenReply()
    }

    private func registerGlobalVoiceShortcut(showFailure: Bool) {
        guard hotKeyRef == nil else { return }

        if hotKeyHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let controllerPointer = UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self).toOpaque()
            )
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let controller = Unmanaged<JarvisMenuController>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    DispatchQueue.main.async {
                        controller.toggleTalk()
                    }
                    return noErr
                },
                1,
                &eventType,
                controllerPointer,
                &hotKeyHandler
            )
            if handlerStatus != noErr {
                UserDefaults.standard.set(false, forKey: voiceShortcutDefaultsKey)
                if showFailure {
                    showAlert(
                        title: "Voice shortcut unavailable",
                        message: "macOS could not register Control-Space for Jarvis."
                    )
                }
                return
            }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4A525653), id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyRef = reference
        } else {
            UserDefaults.standard.set(false, forKey: voiceShortcutDefaultsKey)
            if showFailure {
                showAlert(
                    title: "Voice shortcut unavailable",
                    message: "Control-Space is already in use or could not be registered."
                )
            }
        }
    }

    private func unregisterGlobalVoiceShortcut() {
        if let reference = hotKeyRef {
            UnregisterEventHotKey(reference)
            hotKeyRef = nil
        }
    }

    @objc private func toggleTalk() {
        switch voiceRecorder.state {
        case .idle:
            guard !voiceFlowBusy else { return }
            startVoiceRecording()
        case .authorizing:
            voiceRecorder.cancel()
            completeVoiceFlow()
            refreshMenuState()
        case .recording:
            stopVoiceRecording()
        case .transcribing:
            return
        }
    }

    private func startVoiceRecording(playReadySound: Bool = false) {
        voiceFlowBusy = true
        presenceHUD.show(.listening, on: statusItem.button?.window?.screen)
        voiceRecorder.setPreserveCompletedAudio(ownerVoiceLockEnabled)
        let inheritedNoiseFloorDB = wakeWordListener.calibratedNoiseFloorDB()
        wakeWordListener.stop()
        makeRazerMicrophoneDefaultInput()
        wakeListeningVisualActive = false
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != jarvisBundleIdentifier {
            voiceTargetApplication = frontmost
        }
        voiceRecorder.authorizeAndStart(
            initialNoiseFloorDB: inheritedNoiseFloorDB,
            onSilenceDetected: { [weak self] in
                guard let self, self.voiceRecorder.state == .recording else { return }
                self.stopVoiceRecording()
            }
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if playReadySound {
                    if let readySound = NSSound(named: "Tink") {
                        readySound.volume = 0.22
                        readySound.play()
                    }
                }
            case .failure(let error):
                self.presentVoiceError(error)
                self.completeVoiceFlow()
            }
            self.refreshMenuState()
        }
        refreshMenuState()
    }

    private func stopVoiceRecording() {
        voiceRecorder.stop { [weak self] result in
            guard let self else { return }
            let ownerVoiceSample = self.voiceRecorder.takeCompletedAudioURL()
            self.refreshMenuState()
            switch result {
            case .success(let transcript):
                if isSiriWakeTranscript(transcript) {
                    if let ownerVoiceSample {
                        try? FileManager.default.removeItem(at: ownerVoiceSample)
                    }
                    self.completeVoiceFlow()
                    self.handoffToSiri()
                    return
                }
                if self.liveVoiceDiagnosticActive {
                    if let ownerVoiceSample {
                        try? FileManager.default.removeItem(at: ownerVoiceSample)
                    }
                    self.liveVoiceDiagnosticActive = false
                    logVoiceDiagnostic(
                        "live_voice_diagnostic_completed chars=\(transcript.count)"
                    )
                    self.completeVoiceFlow()
                } else {
                    self.verifyOwnerVoiceSample(ownerVoiceSample) {
                        [weak self] accepted in
                        guard let self else { return }
                        if accepted {
                            self.prepareTranscriptPreview(transcript)
                        } else {
                            self.rejectUnverifiedVoice()
                        }
                    }
                }
            case .failure(let error):
                if let ownerVoiceSample {
                    try? FileManager.default.removeItem(at: ownerVoiceSample)
                }
                let wasDiagnostic = self.liveVoiceDiagnosticActive
                if wasDiagnostic {
                    self.liveVoiceDiagnosticActive = false
                    logVoiceDiagnostic(
                        "live_voice_diagnostic_failed " + errorDiagnostic(error)
                    )
                }
                if !wasDiagnostic {
                    self.presentVoiceError(error)
                }
                self.completeVoiceFlow()
            }
        }
        refreshMenuState()
    }

    private func presentVoiceError(_ error: Error) {
        let message = error.localizedDescription
        var settingsURL: URL?
        if let voiceError = error as? VoiceSessionError {
            switch voiceError {
            case .microphoneDenied:
                settingsURL = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
            case .speechDenied:
                settingsURL = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                )
            default:
                break
            }
        }
        if let settingsURL {
            let alert = NSAlert()
            alert.messageText = "Voice permission required"
            alert.informativeText = message + " Enable it in Privacy & Security, then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Privacy Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }
        showAlert(title: "Jarvis voice input", message: message)
    }

    private func runPythonCapture(
        _ arguments: [String],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let process = pythonProcess(arguments: arguments, capture: true),
              let pipe = process.standardOutput as? Pipe else {
            completion(.failure(NSError(
                domain: jarvisBundleIdentifier,
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis's local core is unavailable."]
            )))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                self.detachedProcessLock.lock()
                self.detachedProcesses.append(process)
                self.detachedProcessLock.unlock()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(data)) }
                } else {
                    let detail = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let error = NSError(
                        domain: jarvisBundleIdentifier,
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: detail ?? "Jarvis command failed."]
                    )
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func prepareTranscriptPreview(_ transcript: String) {
        presenceHUD.show(.thinking, on: statusItem.button?.window?.screen)
        var arguments = ["voice-intent", transcript]
        let localContext = localNavigationContext(for: transcript)
        if !localContext.isEmpty {
            arguments.append(contentsOf: ["--local-context", localContext])
        }
        runPythonCapture(arguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showAlert(title: "Could not prepare voice request", message: error.localizedDescription)
                self.completeVoiceFlow()
            case .success(let data):
                do {
                    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let title = payload["title"] as? String else {
                        throw NSError(
                            domain: jarvisBundleIdentifier,
                            code: 20,
                            userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsafe voice request."]
                        )
                    }
                    let intentKind = payload["kind"] as? String ?? "unknown"
                    let requiresConfirmation = payload["requires_confirmation"] as? Bool ?? true
                    guard requiresConfirmation || intentKind == "local_conversation" else {
                        throw NSError(
                            domain: jarvisBundleIdentifier,
                            code: 20,
                            userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsafe voice request."]
                        )
                    }
                    let intentSource = payload["source"] as? String ?? "unknown"
                    let intentActions = (payload["actions"] as? [[String: Any]])?.count ?? 0
                    let heardTranscript = payload["heard_transcript"] as? String ?? transcript
                    let interpretedTranscript = payload["transcript"] as? String ?? transcript
                    let interpretationReason = payload["interpretation_reason"] as? String ?? "exact"
                    let interpretationChanged = heardTranscript.compare(
                        interpretedTranscript,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != .orderedSame
                    logVoiceDiagnostic(
                        "voice_intent kind=\(intentKind) source=\(intentSource) "
                        + "actions=\(intentActions) interpreted=\(interpretationChanged) "
                        + "reason=\(interpretationReason)"
                    )
                    self.showTranscriptPreview(
                        heardTranscript: heardTranscript,
                        interpretedTranscript: interpretedTranscript,
                        actionTitle: title,
                        intentPayload: payload
                    )
                } catch {
                    self.showAlert(title: "Could not prepare voice request", message: error.localizedDescription)
                    self.completeVoiceFlow()
                }
            }
        }
    }

    private func showTranscriptPreview(
        heardTranscript: String,
        interpretedTranscript: String,
        actionTitle: String,
        intentPayload: [String: Any]
    ) {
        let kind = intentPayload["kind"] as? String ?? "jarvis_request"
        if kind == "local_action" {
            guard let actions = intentPayload["actions"] as? [[String: Any]],
                  !actions.isEmpty else {
                showAlert(title: "Local action rejected", message: "Jarvis produced no safe actions.")
                completeVoiceFlow()
                return
            }
            showLocalActionApproval(
                heardTranscript: heardTranscript,
                interpretedTranscript: interpretedTranscript,
                summary: actionTitle,
                actions: actions,
                confirmationLevel: intentPayload["confirmation_level"] as? String ?? "standard"
            )
            return
        }
        if kind == "local_conversation" {
            let reply = intentPayload["reply"] as? String ?? ""
            guard !reply.isEmpty else {
                showAlert(title: "Local response unavailable", message: "Nothing was generated.")
                completeVoiceFlow()
                return
            }
            followUpPending = spokenResponsesEnabled && conversationFollowupsEnabled
            runDetached([
                "record-conversation",
                interpretedTranscript,
                "--reply", reply,
                "--source", intentPayload["source"] as? String ?? "local"
            ])
            if spokenResponsesEnabled {
                speakJarvisReply(reply)
            } else {
                showAlert(title: "Jarvis", message: reply)
            }
            completeVoiceFlow()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Review voice command"
        let transcriptReview = voiceTranscriptReview(
            heard: heardTranscript,
            interpreted: interpretedTranscript
        )
        if kind == "scan_app_window" {
            let target = intentPayload["scan_target"] as? String ?? "the requested app"
            let route = (intentPayload["route"] as? String ?? "chat").capitalized
            alert.informativeText = (
                "\(transcriptReview)\n\nProposed request: \(actionTitle).\n\n"
                + "Nothing has been captured or sent. Confirming captures exactly one open "
                + "\(target) window without bringing that app forward, then sends it to Jarvis "
                + "\(route)."
            )
        } else {
            alert.informativeText = (
                "\(transcriptReview)\n\nProposed request: \(actionTitle).\n\n"
                + "Nothing has been sent or run. Confirming sends this request to Jarvis; "
                + "any action that changes your Mac or another system still requires a separate approval."
            )
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            runDetached(["voice-dispatch", interpretedTranscript, "--confirmed"])
        }
        completeVoiceFlow()
    }

    private func localActionDescription(_ action: [String: Any]) -> String {
        let type = action["type"] as? String ?? "unknown"
        let payload = action["payload"] as? [String: Any] ?? [:]
        switch type {
        case "open_app":
            return "Open app: \(payload["name"] as? String ?? "")"
        case "open_url":
            return "Open URL: \(payload["url"] as? String ?? "")"
        case "open_chrome_url":
            return "Open in the owner's approved Chrome profile: \(payload["url"] as? String ?? "")"
        case "close_chrome_tab":
            return "Close exactly one Chrome tab matching: \(payload["query"] as? String ?? "")"
        case "quit_app":
            return "Quit normally (never force quit): \(payload["name"] as? String ?? "")"
        case "move_resize_window":
            let app = payload["target"] as? String ?? payload["app"] as? String ?? ""
            let display = payload["display"] as? String ?? ""
            let layout = (payload["layout"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
            let percent = payload["percent"] as? NSNumber
            let detail = percent == nil ? layout : "\(percent!.intValue)% of display area"
            return "Move/resize \(app) on \(display): \(detail)"
        case "open_file":
            return "Open file: \(payload["path"] as? String ?? "")"
        case "reveal_file":
            return "Reveal in Finder: \(payload["path"] as? String ?? "")"
        case "copy_to_clipboard":
            return "Copy text to the clipboard"
        case "type_text":
            let text = payload["text"] as? String ?? ""
            let preview = text.count > 100 ? String(text.prefix(100)) + "…" : text
            return "Type: “\(preview)”"
        case "key_combo":
            let key = payload["key"] as? String ?? ""
            let modifiers = payload["modifiers"] as? [String] ?? []
            return "Press: \((modifiers + [key]).joined(separator: " + "))"
        case "click_ui":
            return "Click the visible control named: \(payload["label"] as? String ?? "")"
        case "focus_ui":
            return "Focus the visible field named: \(payload["label"] as? String ?? "")"
        case "verify_ui":
            return "Continue only if this is visible: \(payload["label"] as? String ?? "")"
        case "scroll":
            return "Scroll \(payload["direction"] as? String ?? "") (\(payload["amount"] as? String ?? ""))"
        case "wait":
            return "Wait \(payload["seconds"] as? Double ?? 0) seconds for the interface"
        case "set_tradingview_interval":
            return "Set TradingView interval to \(payload["minutes"] as? NSNumber ?? 0) minutes"
        case "prepare_tradingview_capture":
            return "Restore the MGC and DXY layout, close the account panel, and fit both charts"
        case "mark_tradingview_ny_range_fib":
            return "Mark the latest completed New York range on the verified MGC 1-minute chart with the saved Fib"
        case "send_active_window_to_work":
            return "Capture the active TradingView window and send it to Jarvis Work for analysis"
        case "send_tradingview_review_to_work":
            return "Capture fitted 5m, 15m, 1h, and 4h MGC+DXY charts and send one review to Work"
        case "create_folder":
            return "Create folder: \(payload["path"] as? String ?? "")"
        case "move_file":
            return "Move: \(payload["source"] as? String ?? "") → \(payload["destination"] as? String ?? "")"
        case "trash_file":
            return "Move to Trash: \(payload["path"] as? String ?? "")"
        case "open_settings":
            return "Open System Settings: \(payload["pane"] as? String ?? "")"
        case "run_shortcut":
            return "Run Apple Shortcut: \(payload["name"] as? String ?? "")"
        case "send_message":
            let app = payload["app"] as? String ?? ""
            let recipient = payload["recipient"] as? String ?? ""
            let text = payload["text"] as? String ?? ""
            let preview = text.count > 160 ? String(text.prefix(160)) + "…" : text
            return "Send with \(app) to \(recipient): “\(preview)”"
        default:
            return "Unsupported action"
        }
    }

    private func showLocalActionApproval(
        heardTranscript: String,
        interpretedTranscript: String,
        summary: String,
        actions: [[String: Any]],
        confirmationLevel: String
    ) {
        let numbered = actions.enumerated().map {
            "\($0.offset + 1). \(localActionDescription($0.element))"
        }.joined(separator: "\n")
        if confirmationLevel == "standard" && autonomousStandardActionsEnabled {
            showAutonomousActionPreview(
                heardTranscript: heardTranscript,
                interpretedTranscript: interpretedTranscript,
                summary: summary,
                numberedActions: numbered,
                actions: actions
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = "Approve Mac actions"
        let requiresTypedConfirmation = confirmationLevel == "sensitive" || confirmationLevel == "external"
        let confirmationPhrase = confirmationLevel == "external" ? "SEND" : "CONFIRM"
        var warning = "These actions have not run. Approve only if every step is correct."
        if confirmationLevel == "external" {
            warning += " This will send information outside your Mac."
        } else if confirmationLevel == "sensitive" {
            warning += " This can change files, settings, or run an Apple Shortcut."
        }
        let transcriptReview = voiceTranscriptReview(
            heard: heardTranscript,
            interpreted: interpretedTranscript
        )
        alert.informativeText = (
            "\(transcriptReview)\n\nJarvis proposes: \(summary)\n\n"
            + "\(numbered)\n\n\(warning)"
        )
        alert.alertStyle = .warning
        var confirmationField: NSTextField?
        if requiresTypedConfirmation {
            let label = NSTextField(labelWithString: "Type \(confirmationPhrase) to authorize exactly these steps:")
            let field = NSTextField(string: "")
            field.placeholderString = confirmationPhrase
            let stack = NSStackView(views: [label, field])
            stack.orientation = .vertical
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 420, height: 52)
            alert.accessoryView = stack
            confirmationField = field
        }
        alert.addButton(withTitle: "Approve and Run")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            completeVoiceFlow()
            return
        }
        if let field = confirmationField,
           field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != confirmationPhrase {
            showAlert(
                title: "Actions canceled",
                message: "The required confirmation phrase did not match. Nothing ran."
            )
            completeVoiceFlow()
            return
        }
        runLocalActions(actions)
        completeVoiceFlow()
    }

    private func showAutonomousActionPreview(
        heardTranscript: String,
        interpretedTranscript: String,
        summary: String,
        numberedActions: String,
        actions: [[String: Any]]
    ) {
        clearPendingAutonomousAction()
        let alert = NSAlert()
        alert.messageText = "Jarvis is acting"
        let transcriptReview = voiceTranscriptReview(
            heard: heardTranscript,
            interpreted: interpretedTranscript
        )
        alert.informativeText = (
            "\(transcriptReview)\n\n\(summary)\n\n\(numberedActions)\n\n"
            + "Running automatically. Choose Cancel only if this is not what you intended."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel Action")
        alert.buttons.first?.target = self
        alert.buttons.first?.action = #selector(cancelPendingAutonomousAction)
        pendingAutonomousActions = actions
        autonomousPreviewAlert = alert
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(runPendingAutonomousAction),
            userInfo: nil,
            repeats: false
        )
        autonomousActionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func runPendingAutonomousAction() {
        let actions = pendingAutonomousActions
        clearPendingAutonomousAction()
        if let actions { runLocalActions(actions) }
        completeVoiceFlow()
    }

    @objc private func cancelPendingAutonomousAction() {
        clearPendingAutonomousAction()
        completeVoiceFlow()
    }

    private func clearPendingAutonomousAction() {
        autonomousActionTimer?.invalidate()
        autonomousActionTimer = nil
        pendingAutonomousActions = nil
        autonomousPreviewAlert?.window.orderOut(nil)
        autonomousPreviewAlert = nil
    }

    private func runLocalActions(_ actions: [[String: Any]]) {
        do {
            try executeLocalActions(actions)
        } catch {
            showCommandError(title: "Jarvis local action failed", message: error.localizedDescription)
        }
    }

    private func requireInputControlPermission() throws {
        let axTrusted = AXIsProcessTrusted()
        let eventPosting = CGPreflightPostEventAccess()
        guard axTrusted else {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 31,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "macOS has not granted Accessibility control to the running Jarvis app. "
                        + "Approve the prompt, then choose Quit Jarvis and reopen it once."
                ]
            )
        }
        if !eventPosting {
            _ = CGRequestPostEventAccess()
        }
    }

    private func activateVoiceTarget() {
        guard let target = voiceTargetApplication, !target.isTerminated else { return }
        _ = target.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.25)
        invalidateAccessibilityScene()
    }

    private func activateAndVerifyFrontmost(
        _ application: NSRunningApplication,
        timeout: TimeInterval = 3.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let forceActivationAfter = Date().addingTimeInterval(min(0.8, timeout / 2.0))
        var yieldedFocus = false
        repeat {
            if application.isTerminated { return false }
            if application.isActive
                || NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == application.processIdentifier {
                invalidateAccessibilityScene()
                return true
            }

            // Since macOS 14, app activation is cooperative. The active Jarvis
            // approval window must explicitly yield before the target's
            // activation request can reliably take focus.
            if !yieldedFocus, NSApp.isActive {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: application)
                }
                yieldedFocus = true
            }

            // Give cold Electron apps a short opportunity to finish launching;
            // after that, continue requesting activation until the deadline.
            if application.isFinishedLaunching || Date() >= forceActivationAfter {
                _ = application.activate(options: [.activateAllWindows])
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private func keyCode(named key: String) -> CGKeyCode? {
        let codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C,
            "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I,
            "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0,
            "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "tab": kVK_Tab,
            "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow,
            "down": kVK_DownArrow, "page_up": kVK_PageUp,
            "page_down": kVK_PageDown, "home": kVK_Home, "end": kVK_End,
            "delete": kVK_Delete,
        ]
        guard let value = codes[key] else { return nil }
        return CGKeyCode(value)
    }

    private func eventFlags(modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    private func postKey(key: String, modifiers: [String]) throws {
        try requireInputControlPermission()
        guard let code = keyCode(named: key),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsupported key."]
            )
        }
        let flags = eventFlags(modifiers: modifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) throws {
        try requireInputControlPermission()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not create keyboard input."]
            )
        }
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer { pointer in
            down.keyboardSetUnicodeString(
                stringLength: characters.count,
                unicodeString: pointer.baseAddress
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func runOpen(arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        detail?.isEmpty == false
                        ? detail!
                        : "macOS could not open the requested destination."
                ]
            )
        }
        Thread.sleep(forTimeInterval: 0.35)
    }

    private func canonicalApplicationName(_ name: String) -> String {
        canonicalCaptureApplicationName(name)
    }

    private func installedApplicationURL(named rawName: String) -> URL? {
        let name = canonicalApplicationName(rawName)
        let fileManager = FileManager.default
        let homeApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplications,
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        for root in roots {
            let candidate = root.appendingPathComponent("\(name).app", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path),
               Bundle(url: candidate)?.bundleIdentifier != nil {
                return candidate
            }
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated
                && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }), let bundleURL = running.bundleURL {
            return bundleURL
        }
        let knownBundleIdentifiers = [
            "Arc": "company.thebrowser.Browser",
            "Calendar": "com.apple.iCal",
            "Discord": "com.hnc.Discord",
            "Firefox": "org.mozilla.firefox",
            "Finder": "com.apple.finder",
            "Google Chrome": "com.google.Chrome",
            "Mail": "com.apple.mail",
            "Messages": "com.apple.MobileSMS",
            "Microsoft Edge": "com.microsoft.edgemac",
            "Notes": "com.apple.Notes",
            "Safari": "com.apple.Safari",
            "System Settings": "com.apple.systempreferences",
            "Terminal": "com.apple.Terminal",
            "TradingView": "com.tradingview.tradingviewapp.desktop",
        ]
        guard let identifier = knownBundleIdentifiers[name] else { return nil }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: identifier
        )
    }

    private func openApplication(named name: String) throws {
        let canonicalName = canonicalApplicationName(name)
        guard let applicationURL = installedApplicationURL(named: canonicalName) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 73,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No installed application matched “\(canonicalName)”."
                ]
            )
        }
        let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier

        // Yield while Jarvis still owns the approved-action window. This is the
        // cooperative-activation path for an application that is not yet running.
        if let bundleIdentifier, NSApp.isActive {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.allowsRunningApplicationSubstitution = true
        configuration.promptsUserIfNeeded = true
        let launchState = WorkspaceLaunchState()
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { application, error in
            launchState.finish(application: application, error: error)
        }
        guard launchState.completed.wait(timeout: .now() + 5.0) == .success else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 75,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "macOS did not finish launching \(canonicalName) within five seconds."
                ]
            )
        }
        if let launchError = launchState.error {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 74,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "macOS found \(canonicalName) but could not launch it: "
                        + launchError.localizedDescription,
                    NSUnderlyingErrorKey: launchError,
                ]
            )
        }

        let running = launchState.application ?? bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .first(where: { !$0.isTerminated })
        }
        if let running,
           activateAndVerifyFrontmost(running, timeout: 0.75) {
            return
        }

        // LaunchServices' command-line entry point is a cheap failure-only
        // recovery and supplies a second user-intent activation event. It adds
        // no latency to successful launches.
        logVoiceDiagnostic("app_activation_retry name=\(canonicalName)")
        try runOpen(arguments: ["-a", canonicalName])
        let refreshed = bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .first(where: { !$0.isTerminated })
        } ?? launchState.application
        if let refreshed,
           activateAndVerifyFrontmost(refreshed, timeout: 1.5) {
            logVoiceDiagnostic("app_activation_recovered name=\(canonicalName)")
            return
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 107,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(canonicalName) opened, but macOS did not make it the active app."
            ]
        )
    }

    private func runningApplication(named rawName: String) throws -> NSRunningApplication {
        if rawName == "frontmost" {
            if let target = voiceTargetApplication, !target.isTerminated {
                return target
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != jarvisBundleIdentifier {
                return frontmost
            }
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 121,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not identify the active window."]
            )
        }
        let name = canonicalApplicationName(rawName)
        guard !["jarvis", "finder", "dock", "systemuiserver", "windowserver", "loginwindow"]
                .contains(name.lowercased()) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 122,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis refused to close or reposition that protected system app."]
            )
        }
        if let url = installedApplicationURL(named: name),
           let identifier = Bundle(url: url)?.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
           ).first(where: { !$0.isTerminated }) {
            return running
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return running
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 123,
            userInfo: [NSLocalizedDescriptionKey: "\(name) is not currently running."]
        )
    }

    private func quitApplicationNormally(named name: String) throws {
        let application = try runningApplication(named: name)
        let label = application.localizedName ?? canonicalApplicationName(name)
        guard application.terminate() else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "macOS refused the normal quit request for \(label)."]
            )
        }
        let deadline = Date().addingTimeInterval(4.0)
        while !application.isTerminated && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.10)
        }
        guard application.isTerminated else {
            _ = application.activate(options: [.activateAllWindows])
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 125,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(label) did not quit, possibly because it is showing an unsaved-work prompt. Jarvis did not force quit it."
                ]
            )
        }
    }

    private func closeUniqueChromeTab(matching query: String) throws {
        _ = try approvedChromeProfileDirectory()
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).contains(where: { !$0.isTerminated }) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 126,
                userInfo: [NSLocalizedDescriptionKey: "Google Chrome is not currently running."]
            )
        }
        let script = """
        on run argv
            set needle to item 1 of argv
            tell application "Google Chrome"
                set matchedWindows to {}
                set matchedTabs to {}
                set matchedTitles to {}
                repeat with windowIndex from 1 to count of windows
                    set tabCount to count of tabs of window windowIndex
                    repeat with tabIndex from 1 to tabCount
                        set candidateTab to tab tabIndex of window windowIndex
                        set candidateTitle to title of candidateTab as text
                        set candidateURL to URL of candidateTab as text
                        ignoring case
                            if candidateTitle contains needle or candidateURL contains needle then
                                set end of matchedWindows to windowIndex
                                set end of matchedTabs to tabIndex
                                set end of matchedTitles to candidateTitle
                            end if
                        end ignoring
                    end repeat
                end repeat
                if (count of matchedTabs) is 0 then error "No Chrome tab matched “" & needle & "”."
                if (count of matchedTabs) is greater than 1 then error "More than one Chrome tab matched “" & needle & "”. Use a more specific title or URL."
                set matchedWindow to item 1 of matchedWindows
                set matchedTab to item 1 of matchedTabs
                set matchedTitle to item 1 of matchedTitles
                close tab matchedTab of window matchedWindow
                return matchedTitle
            end tell
        end run
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, query]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 127,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        detail.isEmpty ? "Jarvis could not close the requested Chrome tab." : detail
                ]
            )
        }
        logVoiceDiagnostic("chrome_tab_closed query_length=\(query.count)")
    }

    private func focusUniqueChromeTab(matching query: String) throws -> Bool {
        _ = try approvedChromeProfileDirectory()
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).contains(where: { !$0.isTerminated }) else { return false }
        let script = """
        on run argv
            set needle to item 1 of argv
            tell application "Google Chrome"
                set matchedWindows to {}
                set matchedTabs to {}
                repeat with windowIndex from 1 to count of windows
                    set tabCount to count of tabs of window windowIndex
                    repeat with tabIndex from 1 to tabCount
                        set candidateTab to tab tabIndex of window windowIndex
                        set candidateTitle to title of candidateTab as text
                        set candidateURL to URL of candidateTab as text
                        ignoring case
                            if candidateTitle contains needle or candidateURL contains needle then
                                set end of matchedWindows to windowIndex
                                set end of matchedTabs to tabIndex
                            end if
                        end ignoring
                    end repeat
                end repeat
                if (count of matchedTabs) is 0 then return "none"
                if (count of matchedTabs) is greater than 1 then return "ambiguous"
                set matchedWindow to item 1 of matchedWindows
                set active tab index of window matchedWindow to item 1 of matchedTabs
                set index of window matchedWindow to 1
                activate
                return "focused"
            end tell
        end run
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, query]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 137,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        detail.isEmpty ? "Jarvis could not inspect Chrome's tabs." : detail
                ]
            )
        }
        if detail == "ambiguous" {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 138,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "More than one Chrome tab matched “\(query)”. Use a more specific title or URL."
                ]
            )
        }
        return detail == "focused"
    }

    private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private func accessibilityFrame(for screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first(where: {
            screenDisplayID($0) == CGMainDisplayID()
        }) else { return screen.visibleFrame }
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.minX,
            y: primary.frame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    private func windowElement(for application: NSRunningApplication) throws -> AXUIElement {
        try requireInputControlPermission()
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                attribute as CFString,
                &raw
            ) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                return unsafeBitCast(raw, to: AXUIElement.self)
            }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 128,
            userInfo: [NSLocalizedDescriptionKey: "The requested app has no movable main window."]
        )
    }

    private func windowElements(for application: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &raw
        ) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func resolvedWindowTarget(
        named rawTarget: String
    ) throws -> (application: NSRunningApplication, window: AXUIElement) {
        try requireInputControlPermission()
        let lowered = rawTarget.lowercased()
        guard !["jarvis", "finder", "dock", "systemuiserver", "windowserver", "loginwindow"]
                .contains(lowered) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 139,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis refused to reposition that protected system app."]
            )
        }
        let farmRPGTarget = ["farm rpg", "farmrpg"].contains(lowered)
        if !farmRPGTarget,
           let application = try? runningApplication(named: rawTarget),
           let window = try? windowElement(for: application) {
            return (application, window)
        }

        let needle = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [(NSRunningApplication, AXUIElement)] = []
        for application in NSWorkspace.shared.runningApplications where
            application.activationPolicy == .regular
            && !application.isTerminated
            && application.bundleIdentifier != jarvisBundleIdentifier {
            if farmRPGTarget && application.bundleIdentifier != "com.google.Chrome" {
                continue
            }
            for window in windowElements(for: application) {
                let title = accessibleString(
                    window,
                    attribute: kAXTitleAttribute as CFString
                ).lowercased()
                if !title.isEmpty && title.contains(needle) {
                    matches.append((application, window))
                }
            }
        }
        if matches.count == 1, let match = matches.first {
            return (match.0, match.1)
        }
        if matches.count > 1 {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 140,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "More than one window matched “\(rawTarget)”. Use a more specific window title."
                ]
            )
        }

        let chromeQuery = farmRPGTarget ? "farmrpg" : rawTarget
        if try focusUniqueChromeTab(matching: chromeQuery),
           let chrome = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.google.Chrome"
           ).first(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.20)
            return (chrome, try windowElement(for: chrome))
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 141,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No running app, visible window title, or unique Chrome tab matched “\(rawTarget)”."
            ]
        )
    }

    private func pointValue(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard
              AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeValue(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard
              AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func resolvedScreen(
        named name: String,
        currentWindowFrame: CGRect
    ) throws -> NSScreen {
        let screens = NSScreen.screens
        let lowered = name.lowercased()
        if lowered == "current" {
            let center = CGPoint(x: currentWindowFrame.midX, y: currentWindowFrame.midY)
            return screens.first(where: { accessibilityFrame(for: $0).contains(center) })
                ?? NSScreen.main
                ?? screens[0]
        }
        let match = screens.filter { screen in
            guard let identifier = screenDisplayID(screen) else { return false }
            if lowered == "mac" { return CGDisplayIsBuiltin(identifier) != 0 }
            if lowered == "xb283k" {
                let label = screen.localizedName.lowercased()
                return CGDisplayIsBuiltin(identifier) == 0
                    && (label.contains("xb283k") || label.contains("xb2k"))
            }
            return false
        }
        guard match.count == 1, let screen = match.first else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 129,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis could not uniquely resolve the \(name) display. Connected displays: "
                        + screens.map(\.localizedName).joined(separator: ", ")
                ]
            )
        }
        return screen
    }

    private func setWindowFrame(
        target rawTarget: String,
        display: String,
        layout: String,
        percent: Double? = nil
    ) throws {
        let resolved = try resolvedWindowTarget(named: rawTarget)
        let application = resolved.application
        let window = resolved.window
        guard let currentPosition = pointValue(window, attribute: kAXPositionAttribute as CFString),
              let currentSize = sizeValue(window, attribute: kAXSizeAttribute as CFString) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 130,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not read the current window frame."]
            )
        }
        let currentFrame = CGRect(origin: currentPosition, size: currentSize)
        let screen = try resolvedScreen(named: display, currentWindowFrame: currentFrame)
        let visible = accessibilityFrame(for: screen).insetBy(dx: 6, dy: 6)
        let target: CGRect
        switch layout {
        case "maximize":
            target = visible
        case "left_half":
            target = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case "right_half":
            target = CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case "top_half":
            target = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height / 2)
        case "bottom_half":
            target = CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: visible.height / 2)
        case "top_left_quarter":
            target = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        case "top_right_quarter":
            target = CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        case "bottom_left_quarter":
            target = CGRect(x: visible.minX, y: visible.midY, width: visible.width / 2, height: visible.height / 2)
        case "bottom_right_quarter":
            target = CGRect(x: visible.midX, y: visible.midY, width: visible.width / 2, height: visible.height / 2)
        case "percent":
            guard let percent, percent >= 10, percent <= 100 else {
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 142,
                    userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid window percentage."]
                )
            }
            let scale = sqrt(percent / 100.0)
            let size = CGSize(width: visible.width * scale, height: visible.height * scale)
            target = CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case "center":
            let size = CGSize(width: visible.width * 0.80, height: visible.height * 0.80)
            target = CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case "preserve":
            let size = CGSize(
                width: min(max(currentSize.width, 360), visible.width),
                height: min(max(currentSize.height, 240), visible.height)
            )
            target = CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        default:
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 131,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsupported window layout."]
            )
        }
        var targetSize = target.size
        var targetPosition = target.origin
        guard let sizeAXValue = AXValueCreate(.cgSize, &targetSize),
              let positionValue = AXValueCreate(.cgPoint, &targetPosition),
              AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                sizeAXValue
              ) == .success,
              AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue
              ) == .success else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 132,
                userInfo: [NSLocalizedDescriptionKey: "The app refused the requested window size or position."]
            )
        }
        Thread.sleep(forTimeInterval: 0.20)
        guard let finalPosition = pointValue(window, attribute: kAXPositionAttribute as CFString),
              let finalSize = sizeValue(window, attribute: kAXSizeAttribute as CFString),
              abs(finalPosition.x - target.minX) <= 12,
              abs(finalPosition.y - target.minY) <= 12,
              abs(finalSize.width - target.width) <= 16,
              abs(finalSize.height - target.height) <= 16 else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 133,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not verify the final window frame."]
            )
        }
        _ = activateAndVerifyFrontmost(application)
        logVoiceDiagnostic(
            "window_layout target=\(application.localizedName ?? rawTarget) "
            + "display=\(screen.localizedName) layout=\(layout)"
        )
    }

    private func approvedChromeProfileDirectory() throws -> String {
        guard !approvedChromeProfileEmail.isEmpty else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 74,
                userInfo: [NSLocalizedDescriptionKey:
                    "Set approved_chrome_profile_email in ~/Jarvis/Data/no_api_config.json before using pinned Chrome actions."]
            )
        }
        let localStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        let data = try Data(contentsOf: localStateURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 75,
                userInfo: [NSLocalizedDescriptionKey: "Chrome's local profile mapping is unavailable."]
            )
        }
        for (directory, rawProfile) in cache {
            guard let values = rawProfile as? [String: Any] else { continue }
            if values["user_name"] as? String == approvedChromeProfileEmail {
                return directory
            }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 76,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The approved Chrome account is not present. Jarvis refused to use another profile."
            ]
        )
    }

    private func isPrivateWebHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return host == "::" || host == "::1" || host.hasPrefix("fc")
                || host.hasPrefix("fd") || host.hasPrefix("fe8")
                || host.hasPrefix("fe9") || host.hasPrefix("fea")
                || host.hasPrefix("feb")
        }
        let pieces = host.split(separator: ".")
        guard pieces.count == 4,
              let first = Int(pieces[0]), let second = Int(pieces[1]),
              pieces.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            return false
        }
        return first == 0 || first == 10 || first == 127 || first >= 224
            || (first == 100 && (64...127).contains(second))
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 198 && (18...19).contains(second))
    }

    private func validatedWebURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 80 || components.port == 443,
              !isPrivateWebHost(host),
              let url = components.url else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 112,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis rejected an unsafe, private, credentialed, or nonstandard web URL."
                ]
            )
        }
        return url
    }

    private func openApprovedChromeURL(_ value: String) throws {
        let url = try validatedWebURL(value)
        let profileDirectory = try approvedChromeProfileDirectory()
        guard let chromeURL = installedApplicationURL(named: "Google Chrome") else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 78,
                userInfo: [NSLocalizedDescriptionKey: "Google Chrome is not installed."]
            )
        }
        let executable = chromeURL
            .appendingPathComponent("Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 79,
                userInfo: [NSLocalizedDescriptionKey: "Google Chrome's executable is unavailable."]
            )
        }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--profile-directory=\(profileDirectory)",
            "--new-window",
            url.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        Thread.sleep(forTimeInterval: 0.8)
        if !process.isRunning && process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        detail?.isEmpty == false ? detail! : "Chrome could not open the approved profile."
                ]
            )
        }
        guard let chrome = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).first, activateAndVerifyFrontmost(chrome) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 108,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Chrome opened the approved profile, but Jarvis could not verify its active window."
                ]
            )
        }
        logVoiceDiagnostic("open_chrome_url host=\(url.host ?? "unknown")")
    }

    private func runProcess(executable: String, arguments: [String], failureMessage: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : failureMessage]
            )
        }
    }

    private func safeLocalFileURL(_ rawPath: String, mustExist: Bool) throws -> URL {
        guard rawPath.hasPrefix("/") else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis permits only absolute local file paths."]
            )
        }
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        var candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        if mustExist {
            candidate = candidate.resolvingSymlinksInPath()
        } else {
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            candidate = parent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        }
        let homePrefix = home.path + "/"
        guard candidate.path.hasPrefix(homePrefix), candidate.path != home.path else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis file actions are limited to the owner's home folder."]
            )
        }
        let relative = String(candidate.path.dropFirst(homePrefix.count))
        let firstComponent = relative.split(separator: "/").first.map(String.init) ?? ""
        let protectedPrefixes = [
            home.appendingPathComponent("Library").path,
            home.appendingPathComponent(".Trash").path,
            home.appendingPathComponent("Jarvis/App").path,
            home.appendingPathComponent("Jarvis/Code").path,
            home.appendingPathComponent("Jarvis/Data").path,
            home.appendingPathComponent("Jarvis/Models").path,
        ]
        guard !firstComponent.hasPrefix("."),
              !protectedPrefixes.contains(where: {
                  candidate.path == $0 || candidate.path.hasPrefix($0 + "/")
              }) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 45,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis protected app, model, private, and system files from this voice action."]
            )
        }
        if mustExist && !fileManager.fileExists(atPath: candidate.path) {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 46,
                userInfo: [NSLocalizedDescriptionKey: "The requested file or folder does not exist: \(candidate.path)"]
            )
        }
        return candidate
    }

    private func accessibleString(_ element: AXUIElement, attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func accessibleChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func invalidateAccessibilityScene() {
        accessibilitySceneCache = nil
    }

    private func accessibilityScene(
        for app: NSRunningApplication,
        forceRefresh: Bool = false
    ) -> CachedAccessibilityScene {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           let cached = accessibilitySceneCache,
           cached.pid == app.processIdentifier,
           now - cached.createdAt <= accessibilitySceneCacheLifetimeSeconds {
            return cached
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var entries: [CachedAccessibilityEntry] = []
        var contextLines: [String] = []
        var seenContext = Set<String>()
        while index < queue.count && index < accessibilitySceneMaxElements {
            let (element, depth) = queue[index]
            index += 1
            let rawFields = [
                accessibleString(element, attribute: kAXTitleAttribute as CFString),
                accessibleString(element, attribute: kAXDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXHelpAttribute as CFString),
                accessibleString(element, attribute: kAXRoleDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXValueAttribute as CFString),
                accessibleString(element, attribute: kAXIdentifierAttribute as CFString),
            ]
            let cleanedFields = rawFields.compactMap { raw -> String? in
                let cleaned = raw
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty || cleaned.count > 160 ? nil : cleaned
            }
            if !cleanedFields.isEmpty {
                entries.append(CachedAccessibilityEntry(
                    element: element,
                    fields: cleanedFields.map { $0.lowercased() }
                ))
                for cleaned in cleanedFields where contextLines.count < accessibilitySceneMaxContextLabels {
                    let key = cleaned.lowercased()
                    if seenContext.insert(key).inserted {
                        contextLines.append("Visible UI: \(cleaned)")
                    }
                }
            }
            if depth < 30 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        let scene = CachedAccessibilityScene(
            pid: app.processIdentifier,
            createdAt: now,
            entries: entries,
            contextLines: contextLines
        )
        accessibilitySceneCache = scene
        return scene
    }

    private func localNavigationContext(for transcript: String) -> String {
        guard let target = voiceTargetApplication, !target.isTerminated else { return "" }
        var lines = [
            "Active app: \(target.localizedName ?? "Unknown")",
            "System thermal state: \(currentThermalStateName())",
        ]
        guard navigationNeedsVisibleUI(transcript) else {
            return lines.joined(separator: "\n")
        }
        guard AXIsProcessTrusted() else { return lines.joined(separator: "\n") }
        lines.append(contentsOf: accessibilityScene(for: target).contextLines)
        return lines.joined(separator: "\n")
    }

    private func canPressAccessibleElement(_ element: AXUIElement) -> Bool {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private func findVisibleElement(
        label: String,
        in app: NSRunningApplication,
        requirePress: Bool,
        forceRefresh: Bool = false
    ) -> AXUIElement? {
        let needle = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let scene = accessibilityScene(for: app, forceRefresh: forceRefresh)
        var partialMatch: AXUIElement?
        for entry in scene.entries {
            let eligible = !requirePress || canPressAccessibleElement(entry.element)
            guard eligible else { continue }
            if entry.fields.contains(needle) { return entry.element }
            if partialMatch == nil && entry.fields.contains(where: { $0.contains(needle) }) {
                partialMatch = entry.element
            }
        }
        if partialMatch == nil && !forceRefresh {
            return findVisibleElement(
                label: label,
                in: app,
                requirePress: requirePress,
                forceRefresh: true
            )
        }
        return partialMatch
    }

    private func pressVisibleControl(label: String) throws {
        try requireInputControlPermission()
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != jarvisBundleIdentifier else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 47,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not access the target app's controls."]
            )
        }
        for attempt in 0..<3 {
            if let element = findVisibleElement(
                label: label,
                in: app,
                requirePress: true,
                forceRefresh: attempt > 0
            ), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                invalidateAccessibilityScene()
                if attempt > 0 {
                    logVoiceDiagnostic("action_recovered type=click_ui attempts=\(attempt + 1)")
                }
                return
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: attempt == 0 ? 0.22 : 0.40) }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 49,
            userInfo: [NSLocalizedDescriptionKey: "No visible clickable control matched “\(label)”. Nothing was clicked."]
        )
    }

    private func focusVisibleControl(label: String) throws {
        try requireInputControlPermission()
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != jarvisBundleIdentifier else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 67,
                userInfo: [NSLocalizedDescriptionKey: "No visible field matched “\(label)”. Nothing was focused."]
            )
        }
        for attempt in 0..<3 {
            if let element = findVisibleElement(
                label: label,
                in: app,
                requirePress: false,
                forceRefresh: attempt > 0
            ) {
                let focused = AXUIElementSetAttributeValue(
                    element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                if focused == .success || (
                    canPressAccessibleElement(element)
                    && AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                ) {
                    invalidateAccessibilityScene()
                    if attempt > 0 {
                        logVoiceDiagnostic("action_recovered type=focus_ui attempts=\(attempt + 1)")
                    }
                    return
                }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: attempt == 0 ? 0.22 : 0.40) }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 68,
            userInfo: [NSLocalizedDescriptionKey: "The field was found, but macOS would not focus it."]
        )
    }

    private func verifyVisibleControl(label: String) throws {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != jarvisBundleIdentifier else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 69,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis stopped the remaining steps because “\(label)” was not visible."
                ]
            )
        }
        for attempt in 0..<3 {
            if findVisibleElement(
                label: label,
                in: app,
                requirePress: false,
                forceRefresh: attempt > 0
            ) != nil {
                if attempt > 0 {
                    logVoiceDiagnostic("action_recovered type=verify_ui attempts=\(attempt + 1)")
                }
                return
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: attempt == 0 ? 0.25 : 0.45) }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 69,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Jarvis stopped the remaining steps because “\(label)” was not visible after a fresh scan."
            ]
        )
    }

    private func setTradingViewInterval(minutes: Int) throws {
        let labels: [Int: String] = [
            1: "1 minute", 2: "2 minutes", 3: "3 minutes", 5: "5 minutes",
            10: "10 minutes", 15: "15 minutes", 30: "30 minutes",
            60: "1 hour", 240: "4 hours", 1440: "1 day",
        ]
        guard let label = labels[minutes] else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 81,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsupported chart interval."]
            )
        }
        try requireInputControlPermission()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.localizedName?.lowercased() == "tradingview" else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 82,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis stopped because TradingView was not the active application."
                ]
            )
        }
        // TradingView replaces its toolbar accessibility nodes after closing a
        // panel, changing an interval, or opening a layout popover. Never reuse
        // a cached AX element across those mutations.
        for attempt in 0..<3 {
            invalidateAccessibilityScene()
            if let control = findVisibleElement(
                label: label,
                in: app,
                requirePress: true,
                forceRefresh: true
            ), AXUIElementPerformAction(control, kAXPressAction as CFString) == .success {
                invalidateAccessibilityScene()
                Thread.sleep(forTimeInterval: 0.45)
                if let selected = findVisibleElement(
                    label: label,
                    in: app,
                    requirePress: true,
                    forceRefresh: true
                ), accessibleString(
                    selected,
                    attribute: kAXValueAttribute as CFString
                ) == "1" {
                    logVoiceDiagnostic("tradingview_interval_selected minutes=\(minutes)")
                    return
                }
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.20 : 0.35)
            }
        }
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 84,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "TradingView did not confirm the \(label) interval after a fresh UI scan."
            ]
        )
    }

    private func tradingViewChartContainer(
        symbolPrefix: String,
        in app: NSRunningApplication
    ) -> AXUIElement? {
        let chartNumber = symbolPrefix == "TVC:DXY" ? "Chart #2" : "Chart #1"
        return findVisibleElement(label: chartNumber, in: app, requirePress: false)
    }

    private func tradingViewChartText(
        symbolPrefix: String,
        in app: NSRunningApplication
    ) -> String {
        guard let root = tradingViewChartContainer(symbolPrefix: symbolPrefix, in: app) else {
            return ""
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var labels: [String] = []
        while index < queue.count && index < 300 {
            let (element, depth) = queue[index]
            index += 1
            labels.append(contentsOf: [
                accessibleString(element, attribute: kAXTitleAttribute as CFString),
                accessibleString(element, attribute: kAXDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXHelpAttribute as CFString),
                accessibleString(element, attribute: kAXValueAttribute as CFString),
            ].filter { !$0.isEmpty })
            if depth < 5 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        return labels.joined(separator: " ")
    }

    private func tradingViewChartMatches(
        symbolPrefix: String,
        minutes: Int,
        in app: NSRunningApplication
    ) -> Bool {
        let intervalLabels: [Int: String] = [
            1: "1 minute", 5: "5 minutes", 15: "15 minutes",
            60: "1 hour", 240: "4 hours",
        ]
        guard let expectedInterval = intervalLabels[minutes] else { return false }
        let labels = tradingViewChartText(symbolPrefix: symbolPrefix, in: app)
        return labels.localizedCaseInsensitiveContains(symbolPrefix)
            && labels.localizedCaseInsensitiveContains(", \(expectedInterval)")
    }

    private func restoreTradingViewDualChartLayout(
        in app: NSRunningApplication
    ) throws -> Bool {
        guard let restore = findVisibleElement(
            label: "Restore chart",
            in: app,
            requirePress: true
        ) else { return false }
        guard AXUIElementPerformAction(restore, kAXPressAction as CFString) == .success else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 94,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "TradingView exposed its restore control, but macOS could not press it."
                ]
            )
        }
        invalidateAccessibilityScene()
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    private func closeTradingViewAccountPanel(in app: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            if let closePanel = findVisibleElement(
                label: "Close account manager",
                in: app,
                requirePress: true,
                forceRefresh: true
            ), AXUIElementPerformAction(closePanel, kAXPressAction as CFString) == .success {
                invalidateAccessibilityScene()
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
            invalidateAccessibilityScene()
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    private func tradingViewSyncSwitch(
        optionName: String,
        in app: NSRunningApplication
    ) -> AXUIElement? {
        let needle = optionName.lowercased()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count && index < 3000 {
            let (element, depth) = queue[index]
            index += 1
            let labels = [
                accessibleString(element, attribute: kAXTitleAttribute as CFString),
                accessibleString(element, attribute: kAXDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXHelpAttribute as CFString),
                accessibleString(element, attribute: kAXRoleDescriptionAttribute as CFString),
            ].joined(separator: " ").lowercased()
            let value = accessibleString(
                element,
                attribute: kAXValueAttribute as CFString
            ).lowercased()
            if labels.contains(needle), ["on", "off", "1", "0"].contains(value) {
                return element
            }
            if depth < 30 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func tradingViewSyncRow(
        optionName: String,
        in app: NSRunningApplication
    ) -> AXUIElement? {
        let needle = optionName.lowercased()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count && index < 3000 {
            let (element, depth) = queue[index]
            index += 1
            let role = accessibleString(
                element,
                attribute: kAXRoleAttribute as CFString
            )
            let labels = [
                accessibleString(element, attribute: kAXTitleAttribute as CFString),
                accessibleString(element, attribute: kAXDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXHelpAttribute as CFString),
                accessibleString(element, attribute: kAXValueAttribute as CFString),
            ].joined(separator: " ").lowercased()
            if role == "AXRow", labels.contains(needle), canPressAccessibleElement(element) {
                return element
            }
            if depth < 30 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func setTradingViewSyncOptions(
        enabled: Bool,
        in app: NSRunningApplication
    ) throws {
        try postKey(key: "escape", modifiers: [])
        Thread.sleep(forTimeInterval: 0.15)
        invalidateAccessibilityScene()
        var openedLayoutSetup = false
        for attempt in 0..<3 {
            if let layoutSetup = findVisibleElement(
                label: "Layout setup",
                in: app,
                requirePress: true,
                forceRefresh: true
            ), AXUIElementPerformAction(
                layoutSetup,
                kAXPressAction as CFString
            ) == .success {
                openedLayoutSetup = true
                invalidateAccessibilityScene()
                break
            }
            invalidateAccessibilityScene()
            if attempt < 2 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.20 : 0.35)
            }
        }
        guard openedLayoutSetup else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not open TradingView layout sync."]
            )
        }
        Thread.sleep(forTimeInterval: 0.35)
        let options = ["Interval", "Date range"]
        for optionName in options {
            guard let toggle = tradingViewSyncSwitch(optionName: optionName, in: app) else {
                try? postKey(key: "escape", modifiers: [])
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 102,
                    userInfo: [NSLocalizedDescriptionKey: "Jarvis could not verify TradingView's \(optionName) sync setting."]
                )
            }
            let currentValue = accessibleString(
                toggle,
                attribute: kAXValueAttribute as CFString
            ).lowercased()
            let isEnabled = currentValue == "on" || currentValue == "1"
            if isEnabled != enabled {
                // Current TradingView builds expose the labeled switch itself
                // as pressable; older builds exposed only its containing row.
                // Prefer the semantic control and retain the row fallback.
                var changed = AXUIElementPerformAction(
                    toggle,
                    kAXPressAction as CFString
                ) == .success
                if !changed,
                   let row = tradingViewSyncRow(optionName: optionName, in: app) {
                    changed = AXUIElementPerformAction(
                        row,
                        kAXPressAction as CFString
                    ) == .success
                }
                guard changed else {
                    try? postKey(key: "escape", modifiers: [])
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 103,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis could not change TradingView's \(optionName) sync setting."]
                    )
                }
                invalidateAccessibilityScene()
                Thread.sleep(forTimeInterval: 0.25)
                guard let verified = tradingViewSyncSwitch(optionName: optionName, in: app) else {
                    try? postKey(key: "escape", modifiers: [])
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 104,
                        userInfo: [NSLocalizedDescriptionKey: "TradingView did not confirm \(optionName) sync."]
                    )
                }
                let verifiedValue = accessibleString(
                    verified,
                    attribute: kAXValueAttribute as CFString
                ).lowercased()
                let verifiedEnabled = verifiedValue == "on" || verifiedValue == "1"
                guard verifiedEnabled == enabled else {
                    try? postKey(key: "escape", modifiers: [])
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 104,
                        userInfo: [NSLocalizedDescriptionKey: "TradingView did not confirm \(optionName) sync."]
                    )
                }
            }
        }
        try postKey(key: "escape", modifiers: [])
        invalidateAccessibilityScene()
        Thread.sleep(forTimeInterval: 0.2)
        logVoiceDiagnostic(
            "tradingview_sync_verified interval=\(enabled) date_range=\(enabled)"
        )
    }

    private func fitBothTradingViewCharts(in app: NSRunningApplication) throws {
        guard tradingViewChartText(symbolPrefix: "COMEX_MINI:MGC", in: app)
                .localizedCaseInsensitiveContains("COMEX_MINI:MGC"),
              tradingViewChartText(symbolPrefix: "TVC:DXY", in: app)
                .localizedCaseInsensitiveContains("TVC:DXY") else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 105,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not verify the MGC+DXY layout before fitting it."]
            )
        }
        try postKey(key: "r", modifiers: ["option"])
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func setBothTradingViewIntervals(
        minutes: Int,
        in app: NSRunningApplication
    ) throws {
        try setTradingViewInterval(minutes: minutes)
        let deadline = Date().addingTimeInterval(3.0)
        repeat {
            if tradingViewChartMatches(symbolPrefix: "COMEX_MINI:MGC", minutes: minutes, in: app),
               tradingViewChartMatches(symbolPrefix: "TVC:DXY", minutes: minutes, in: app) {
                logVoiceDiagnostic("tradingview_dual_interval_selected minutes=\(minutes)")
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        throw NSError(
            domain: jarvisBundleIdentifier,
            code: 95,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Jarvis could not verify both MGC and DXY at the requested timeframe."
            ]
        )
    }

    private func prepareTradingViewCapture() throws {
        try requireInputControlPermission()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.localizedName?.lowercased() == "tradingview" else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 88,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis stopped because TradingView was not active while fitting the chart."
                ]
            )
        }
        let restored = try restoreTradingViewDualChartLayout(in: app)
        let panelClosed = closeTradingViewAccountPanel(in: app)
        try setTradingViewSyncOptions(enabled: true, in: app)
        try fitBothTradingViewCharts(in: app)
        let verifyDeadline = Date().addingTimeInterval(3.0)
        var goldVisible = false
        var dxyVisible = false
        repeat {
            goldVisible = tradingViewChartText(
                symbolPrefix: "COMEX_MINI:MGC",
                in: app
            ).localizedCaseInsensitiveContains("COMEX_MINI:MGC")
            dxyVisible = tradingViewChartText(
                symbolPrefix: "TVC:DXY",
                in: app
            ).localizedCaseInsensitiveContains("TVC:DXY")
            if goldVisible && dxyVisible {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < verifyDeadline
        guard goldVisible && dxyVisible else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 90,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis could not verify both the MGC and DXY charts after fitting them."
                ]
            )
        }
        logVoiceDiagnostic(
            "tradingview_capture_prepared dual_chart=true restored=\(restored) panel_closed=\(panelClosed)"
        )
    }

    private func captureTradingViewWindow(minutes: Int) throws -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jarvis/Information/Trading/Chart Reviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let label = minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        let path = directory.appendingPathComponent(
            "tradingview_review_\(formatter.string(from: Date()))_\(label).png"
        )
        do {
            _ = try captureActiveWindowImage(to: path.path)
        } catch {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 97,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis could not capture the \(label) MGC+DXY review: "
                        + error.localizedDescription
                ]
            )
        }
        logVoiceDiagnostic("tradingview_review_captured timeframe=\(label) path=\(path.path)")
        return path.path
    }

    private func captureTradingViewReview(timeframes: [Int]) throws -> [String] {
        guard timeframes == [5, 15, 60, 240] else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 98,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an incomplete chart review set."]
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.localizedName?.lowercased() == "tradingview" else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "TradingView was no longer active."]
            )
        }
        var paths: [String] = []
        var scanError: Error?
        do {
            try prepareTradingViewCapture()
            for minutes in timeframes {
                try setBothTradingViewIntervals(minutes: minutes, in: app)
                try fitBothTradingViewCharts(in: app)
                paths.append(try captureTradingViewWindow(minutes: minutes))
            }
        } catch {
            scanError = error
        }

        // Always return TradingView to the user's normal technical-analysis
        // state. Cleanup runs even when a capture or timeframe verification
        // fails so Interval and Date Range cannot remain linked accidentally.
        _ = app.activate(options: [])
        let activationDeadline = Date().addingTimeInterval(1.5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier
                != app.processIdentifier,
              Date() < activationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? postKey(key: "escape", modifiers: [])
        invalidateAccessibilityScene()
        Thread.sleep(forTimeInterval: 0.15)
        var cleanupFailures: [String] = []
        do {
            try setBothTradingViewIntervals(minutes: 5, in: app)
            try fitBothTradingViewCharts(in: app)
        } catch {
            cleanupFailures.append("5-minute interval: \(error.localizedDescription)")
        }
        do {
            try setTradingViewSyncOptions(enabled: false, in: app)
        } catch {
            cleanupFailures.append("chart sync: \(error.localizedDescription)")
        }

        if !cleanupFailures.isEmpty {
            logVoiceDiagnostic(
                "tradingview_review_cleanup_failed "
                + cleanupFailures.joined(separator: " | ")
            )
        }
        if let scanError {
            throw scanError
        }
        guard cleanupFailures.isEmpty else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 110,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The scan finished, but Jarvis could not fully restore TradingView: "
                        + cleanupFailures.joined(separator: "; ")
                ]
            )
        }
        logVoiceDiagnostic(
            "tradingview_review_ready images=\(paths.count) final_interval=5m sync=false"
        )
        return paths
    }

    private struct TradingViewDataWindowHandles {
        let date: AXUIElement
        let time: AXUIElement
        let high: AXUIElement
        let low: AXUIElement
    }

    private struct TradingViewBarSample {
        let date: Date
        let timestamp: String
        let high: Double
        let low: Double
        let x: CGFloat
    }

    private struct TradingViewNYRange {
        let day: String
        let high: TradingViewBarSample
        let low: TradingViewBarSample
        let sampleCount: Int
    }

    private func accessibleElementText(_ element: AXUIElement) -> String {
        for attribute in [
            kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
        ] {
            let text = accessibleString(element, attribute: attribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func descendantElement(
        label: String,
        in root: AXUIElement,
        requirePress: Bool
    ) -> AXUIElement? {
        let needle = label.lowercased()
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var partial: AXUIElement?
        while index < queue.count && index < 800 {
            let (element, depth) = queue[index]
            index += 1
            let fields = [
                accessibleString(element, attribute: kAXTitleAttribute as CFString),
                accessibleString(element, attribute: kAXDescriptionAttribute as CFString),
                accessibleString(element, attribute: kAXHelpAttribute as CFString),
                accessibleString(element, attribute: kAXValueAttribute as CFString),
            ].map { $0.lowercased() }.filter { !$0.isEmpty }
            if !requirePress || canPressAccessibleElement(element) {
                if fields.contains(needle) { return element }
                if partial == nil && fields.contains(where: { $0.contains(needle) }) {
                    partial = element
                }
            }
            if depth < 20 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        return partial
    }

    private func pressAccessibilityElement(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 151,
                userInfo: [NSLocalizedDescriptionKey: "TradingView exposed a control that macOS could not press."]
            )
        }
        invalidateAccessibilityScene()
    }

    private func tradingViewMGCIsMaximized(in app: NSRunningApplication) -> Bool {
        findVisibleElement(
            label: "Restore chart",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) != nil && tradingViewChartText(
            symbolPrefix: "COMEX_MINI:MGC",
            in: app
        ).localizedCaseInsensitiveContains("COMEX_MINI:MGC")
    }

    private func maximizeTradingViewMGC(in app: NSRunningApplication) throws -> Bool {
        if tradingViewMGCIsMaximized(in: app) { return false }
        if let restore = findVisibleElement(
            label: "Restore chart",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) {
            try pressAccessibilityElement(restore)
            Thread.sleep(forTimeInterval: 0.45)
        }
        guard let chart = tradingViewChartContainer(
            symbolPrefix: "COMEX_MINI:MGC",
            in: app
        ), tradingViewChartText(
            symbolPrefix: "COMEX_MINI:MGC",
            in: app
        ).localizedCaseInsensitiveContains("COMEX_MINI:MGC"),
              let maximize = descendantElement(
                label: "Maximize chart",
                in: chart,
                requirePress: true
              ) ?? findVisibleElement(
                label: "Maximize chart",
                in: app,
                requirePress: true,
                forceRefresh: true
              ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 152,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not maximize the verified MGC chart."]
            )
        }
        try pressAccessibilityElement(maximize)
        Thread.sleep(forTimeInterval: 0.55)
        guard tradingViewMGCIsMaximized(in: app) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 153,
                userInfo: [NSLocalizedDescriptionKey: "TradingView did not confirm that MGC was maximized."]
            )
        }
        return true
    }

    private func tradingViewPanelIsOpen(in app: NSRunningApplication) -> Bool {
        guard let toggle = findVisibleElement(
            label: "Object tree and data window",
            in: app,
            requirePress: false,
            forceRefresh: true
        ) else { return false }
        let value = accessibleString(toggle, attribute: kAXValueAttribute as CFString).lowercased()
        return value == "1" || value == "on" || value == "true"
    }

    private func setTradingViewDataWindowVisible(
        _ visible: Bool,
        in app: NSRunningApplication
    ) throws {
        if tradingViewPanelIsOpen(in: app) != visible {
            guard let toggle = findVisibleElement(
                label: "Object tree and data window",
                in: app,
                requirePress: true,
                forceRefresh: true
            ) else {
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 154,
                    userInfo: [NSLocalizedDescriptionKey: "Jarvis could not find TradingView's data-window control."]
                )
            }
            try pressAccessibilityElement(toggle)
            Thread.sleep(forTimeInterval: 0.35)
        }
        guard visible else { return }
        guard let tab = findVisibleElement(
            label: "Data window",
            in: app,
            requirePress: false,
            forceRefresh: true
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 155,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not find TradingView's Data window tab."]
            )
        }
        let selected = accessibleString(tab, attribute: kAXValueAttribute as CFString)
        if selected != "1" {
            var changed = false
            if canPressAccessibleElement(tab) {
                changed = AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
            }
            if !changed {
                changed = AXUIElementSetAttributeValue(
                    tab,
                    kAXValueAttribute as CFString,
                    NSNumber(value: 1)
                ) == .success
            }
            guard changed else {
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 156,
                    userInfo: [NSLocalizedDescriptionKey: "TradingView would not select its Data window tab."]
                )
            }
            invalidateAccessibilityScene()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func tradingViewDataWindowHandles(
        in app: NSRunningApplication
    ) -> TradingViewDataWindowHandles? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var dateElement: AXUIElement?
        var timeElement: AXUIElement?
        var highElement: AXUIElement?
        var lowElement: AXUIElement?
        while index < queue.count && index < 3500 {
            let (element, depth) = queue[index]
            index += 1
            let children = accessibleChildren(element)
            let childTexts = children.map(accessibleElementText)
            if dateElement == nil,
               let dateIndex = childTexts.firstIndex(where: { $0.caseInsensitiveCompare("Date") == .orderedSame }),
               dateIndex + 1 < children.count,
               let timeIndex = childTexts.firstIndex(where: { $0.caseInsensitiveCompare("Time") == .orderedSame }),
               timeIndex + 1 < children.count {
                dateElement = children[dateIndex + 1]
                timeElement = children[timeIndex + 1]
            }
            if highElement == nil,
               childTexts.contains(where: { $0.localizedCaseInsensitiveContains("MGC") }),
               let highIndex = childTexts.firstIndex(where: { $0.caseInsensitiveCompare("High") == .orderedSame }),
               highIndex + 1 < children.count,
               let lowIndex = childTexts.firstIndex(where: { $0.caseInsensitiveCompare("Low") == .orderedSame }),
               lowIndex + 1 < children.count {
                highElement = children[highIndex + 1]
                lowElement = children[lowIndex + 1]
            }
            if let dateElement, let timeElement, let highElement, let lowElement {
                return TradingViewDataWindowHandles(
                    date: dateElement,
                    time: timeElement,
                    high: highElement,
                    low: lowElement
                )
            }
            if depth < 30 {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func tradingViewUTCOffsetSeconds(in app: NSRunningApplication) -> Int? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        let expression = try? NSRegularExpression(pattern: #"UTC\s*([+-]\d{1,2})(?::(\d{2}))?"#)
        while index < queue.count && index < 3500 {
            let (element, depth) = queue[index]
            index += 1
            let text = accessibleElementText(element)
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expression?.firstMatch(in: text, range: fullRange),
               let hourRange = Range(match.range(at: 1), in: text),
               let hours = Int(text[hourRange]) {
                var seconds = hours * 3600
                if match.range(at: 2).location != NSNotFound,
                   let minuteRange = Range(match.range(at: 2), in: text),
                   let minutes = Int(text[minuteRange]) {
                    seconds += (hours < 0 ? -1 : 1) * minutes * 60
                }
                return seconds
            }
            if depth < 30 {
                queue.append(contentsOf: accessibleChildren(element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func parseTradingViewPrice(_ text: String) -> Double? {
        Double(
            text.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func tradingViewBarSample(
        handles: TradingViewDataWindowHandles,
        formatter: DateFormatter,
        x: CGFloat
    ) -> TradingViewBarSample? {
        let dateText = accessibleElementText(handles.date)
        let timeText = accessibleElementText(handles.time)
        let timestamp = "\(dateText) \(timeText)"
        guard let date = formatter.date(from: timestamp),
              let high = parseTradingViewPrice(accessibleElementText(handles.high)),
              let low = parseTradingViewPrice(accessibleElementText(handles.low)),
              high >= low else { return nil }
        return TradingViewBarSample(
            date: date,
            timestamp: timestamp,
            high: high,
            low: low,
            x: x
        )
    }

    private func latestCompletedNewYorkRange(
        from samples: [TradingViewBarSample]
    ) -> TradingViewNYRange? {
        guard let newYork = TimeZone(identifier: "America/New_York") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        var grouped: [String: [String: TradingViewBarSample]] = [:]
        var bounds: [String: (minimum: Int, maximum: Int)] = [:]
        for sample in samples {
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: sample.date
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let hour = components.hour,
                  let minute = components.minute else { continue }
            let sessionMinute = hour * 60 + minute
            guard sessionMinute >= 8 * 60 + 30, sessionMinute < 16 * 60 else { continue }
            let dayKey = String(format: "%04d-%02d-%02d", year, month, day)
            grouped[dayKey, default: [:]][sample.timestamp] = sample
            let existing = bounds[dayKey] ?? (sessionMinute, sessionMinute)
            bounds[dayKey] = (
                min(existing.minimum, sessionMinute),
                max(existing.maximum, sessionMinute)
            )
        }
        for dayKey in grouped.keys.sorted(by: >) {
            guard let unique = grouped[dayKey],
                  let span = bounds[dayKey],
                  unique.count >= 180,
                  span.minimum <= 8 * 60 + 35,
                  span.maximum >= 15 * 60 + 55 else { continue }
            let bars = Array(unique.values)
            guard let high = bars.max(by: { $0.high < $1.high }),
                  let low = bars.min(by: { $0.low < $1.low }),
                  high.high > low.low else { continue }
            return TradingViewNYRange(
                day: dayKey,
                high: high,
                low: low,
                sampleCount: bars.count
            )
        }
        return nil
    }

    private func postMouseMove(to point: CGPoint) throws {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 157,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not inspect the chart cursor position."]
            )
        }
        event.post(tap: .cghidEventTap)
    }

    private func postMouseClick(at point: CGPoint) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 158,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not create the approved chart drawing click."]
            )
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        up.post(tap: .cghidEventTap)
    }

    private func ensureTradingViewStrongMagnet(in app: NSRunningApplication) throws {
        guard let magnets = findVisibleElement(
            label: "Magnets",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 159,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not find TradingView's magnet control."]
            )
        }
        try pressAccessibilityElement(magnets)
        Thread.sleep(forTimeInterval: 0.25)
        guard let strong = findVisibleElement(
            label: "Strong magnet",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) else {
            try? postKey(key: "escape", modifiers: [])
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 160,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not select TradingView's Strong magnet mode."]
            )
        }
        try pressAccessibilityElement(strong)
        Thread.sleep(forTimeInterval: 0.2)
        guard let enabled = findVisibleElement(
            label: "Magnet mode snaps drawings",
            in: app,
            requirePress: false,
            forceRefresh: true
        ), ["1", "on", "true"].contains(
            accessibleString(enabled, attribute: kAXValueAttribute as CFString).lowercased()
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 161,
                userInfo: [NSLocalizedDescriptionKey: "TradingView did not confirm Strong magnet mode."]
            )
        }
    }

    private func scanTradingViewNewYorkRange(
        in app: NSRunningApplication,
        chartFrame: CGRect
    ) throws -> TradingViewNYRange {
        guard let handles = tradingViewDataWindowHandles(in: app),
              let utcOffset = tradingViewUTCOffsetSeconds(in: app),
              let chartTimeZone = TimeZone(secondsFromGMT: utcOffset) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 162,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not read TradingView's exact date, time, high, low, or timezone."]
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chartTimeZone
        formatter.dateFormat = "EEE MM/dd/yy hh:mm a"
        let startX = chartFrame.minX + 48
        let endX = chartFrame.maxX - 96
        guard endX - startX >= 420 else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 163,
                userInfo: [NSLocalizedDescriptionKey: "The visible MGC chart is too narrow for an exact New York range scan."]
            )
        }
        let cursorY = chartFrame.midY
        let sampleCount = min(1800, max(500, Int((endX - startX).rounded(.up))))
        var samplesByTimestamp: [String: TradingViewBarSample] = [:]
        for index in 0...sampleCount {
            let progress = CGFloat(index) / CGFloat(sampleCount)
            let x = startX + (endX - startX) * progress
            try postMouseMove(to: CGPoint(x: x, y: cursorY))
            Thread.sleep(forTimeInterval: 0.009)
            if let sample = tradingViewBarSample(handles: handles, formatter: formatter, x: x) {
                samplesByTimestamp[sample.timestamp] = sample
            }
        }
        guard let range = latestCompletedNewYorkRange(
            from: Array(samplesByTimestamp.values)
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 164,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Jarvis could not verify a complete 8:30 AM–4:00 PM New York session in the visible MGC 1-minute data. Nothing was drawn."
                ]
            )
        }
        return range
    }

    private func markTradingViewNYRangeFib() throws {
        try requireInputControlPermission()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.localizedName?.lowercased() == "tradingview" else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 165,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis stopped because TradingView was not active."]
            )
        }
        let panelWasOpen = tradingViewPanelIsOpen(in: app)
        let maximizedByJarvis = try maximizeTradingViewMGC(in: app)
        defer {
            if !panelWasOpen { try? setTradingViewDataWindowVisible(false, in: app) }
            if maximizedByJarvis { _ = try? restoreTradingViewDualChartLayout(in: app) }
        }
        try setTradingViewInterval(minutes: 1)
        guard tradingViewChartMatches(
            symbolPrefix: "COMEX_MINI:MGC",
            minutes: 1,
            in: app
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 166,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not verify COMEX Mini Gold on the 1-minute chart."]
            )
        }
        guard let oneDay = findVisibleElement(
            label: "1 day in 1 minute intervals",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 167,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not select TradingView's 1D range."]
            )
        }
        try pressAccessibilityElement(oneDay)
        Thread.sleep(forTimeInterval: 0.7)
        try setTradingViewDataWindowVisible(true, in: app)
        guard let chart = tradingViewChartContainer(
            symbolPrefix: "COMEX_MINI:MGC",
            in: app
        ), let origin = pointValue(chart, attribute: kAXPositionAttribute as CFString),
           let size = sizeValue(chart, attribute: kAXSizeAttribute as CFString),
           size.width >= 500, size.height >= 350 else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 168,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not verify the MGC chart area."]
            )
        }
        let chartFrame = CGRect(origin: origin, size: size)
        if let cross = findVisibleElement(
            label: "Cross",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) {
            try pressAccessibilityElement(cross)
        }
        let range = try scanTradingViewNewYorkRange(in: app, chartFrame: chartFrame)
        try ensureTradingViewStrongMagnet(in: app)
        guard let fib = findVisibleElement(
            label: "Fib retracement",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 169,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not find the owner's saved Fib retracement tool."]
            )
        }
        try pressAccessibilityElement(fib)
        Thread.sleep(forTimeInterval: 0.2)
        let highY = chartFrame.minY + max(110, chartFrame.height * 0.17)
        let lowY = chartFrame.maxY - max(80, chartFrame.height * 0.13)
        try postMouseClick(at: CGPoint(x: range.high.x, y: highY))
        Thread.sleep(forTimeInterval: 0.18)
        try postMouseClick(at: CGPoint(x: range.low.x, y: lowY))
        Thread.sleep(forTimeInterval: 0.45)
        guard findVisibleElement(
            label: "Undo create Fib retracement",
            in: app,
            requirePress: false,
            forceRefresh: true
        ) != nil else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 170,
                userInfo: [NSLocalizedDescriptionKey: "TradingView did not confirm the Fib drawing, so Jarvis stopped."]
            )
        }
        if let cross = findVisibleElement(
            label: "Cross",
            in: app,
            requirePress: true,
            forceRefresh: true
        ) {
            try? pressAccessibilityElement(cross)
        }
        logVoiceDiagnostic(
            "tradingview_ny_fib_created day=\(range.day) interval=1m "
            + "high=\(range.high.high) low=\(range.low.low) samples=\(range.sampleCount)"
        )
    }

    private func postScroll(direction: String, amount: String) throws {
        try requireInputControlPermission()
        let magnitude: Int32
        switch amount {
        case "small": magnitude = 3
        case "large": magnitude = 14
        default: magnitude = 7
        }
        let vertical: Int32 = direction == "up" ? magnitude : (direction == "down" ? -magnitude : 0)
        let horizontal: Int32 = direction == "left" ? magnitude : (direction == "right" ? -magnitude : 0)
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 50,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not create the approved scroll action."]
            )
        }
        event.post(tap: .cghidEventTap)
    }

    private func openSettingsPane(_ pane: String) throws {
        let destinations: [String: String] = [
            "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "appearance": "x-apple.systempreferences:com.apple.Appearance-Settings.extension",
            "bluetooth": "x-apple.systempreferences:com.apple.BluetoothSettings",
            "desktop": "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
            "displays": "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "keyboard": "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "login_items": "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "microphone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "network": "x-apple.systempreferences:com.apple.Network-Settings.extension",
            "notifications": "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "privacy": "x-apple.systempreferences:com.apple.preference.security",
            "screen_recording": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "sound": "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "trackpad": "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
        ]
        guard let destination = destinations[pane], let url = URL(string: destination),
              NSWorkspace.shared.open(url) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 51,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsupported System Settings pane."]
            )
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func sendApprovedMessage(
        app: String,
        recipient: String,
        text: String,
        subject: String
    ) throws {
        try requireInputControlPermission()
        if app == "Messages" {
            try openApplication(named: "Messages")
            try postKey(key: "n", modifiers: ["command"])
            Thread.sleep(forTimeInterval: 0.35)
            try postText(recipient)
            Thread.sleep(forTimeInterval: 0.25)
            try postKey(key: "return", modifiers: [])
            Thread.sleep(forTimeInterval: 0.35)
            try postText(text)
            Thread.sleep(forTimeInterval: 0.2)
            try postKey(key: "return", modifiers: [])
            return
        }
        guard app == "Mail" else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 52,
                userInfo: [NSLocalizedDescriptionKey: "Direct message sending supports Messages and Mail."]
            )
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        var queryItems = [URLQueryItem(name: "body", value: text)]
        if !subject.isEmpty { queryItems.insert(URLQueryItem(name: "subject", value: subject), at: 0) }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 53,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis could not prepare the approved email."]
            )
        }
        guard let mailURL = installedApplicationURL(named: "Mail") else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 75,
                userInfo: [NSLocalizedDescriptionKey: "Mail is not installed on this Mac."]
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: mailURL,
            configuration: configuration,
            completionHandler: nil
        )
        Thread.sleep(forTimeInterval: 0.8)
        try postKey(key: "d", modifiers: ["command", "shift"])
    }

    private func executeLocalActions(_ actions: [[String: Any]]) throws {
        guard (1...8).contains(actions.count) else {
            throw NSError(
                domain: jarvisBundleIdentifier,
                code: 34,
                userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid action count."]
            )
        }
        var destinationOpened = false
        for (actionIndex, action) in actions.enumerated() {
            guard let type = action["type"] as? String,
                  let payload = action["payload"] as? [String: Any] else {
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 35,
                    userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected a malformed action."]
                )
            }
            let actionStarted = ProcessInfo.processInfo.systemUptime
            var actionSucceeded = false
            defer {
                let durationMS = Int(
                    (ProcessInfo.processInfo.systemUptime - actionStarted) * 1000.0
                )
                logVoiceDiagnostic(
                    "action_step index=\(actionIndex + 1) type=\(type) "
                    + "success=\(actionSucceeded) duration_ms=\(durationMS)"
                )
            }
            switch type {
            case "open_app":
                guard let name = payload["name"] as? String,
                      !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 36,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid app name."]
                    )
                }
                try openApplication(named: name)
                destinationOpened = true
            case "open_url":
                guard let value = payload["url"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 37,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis permits only HTTP and HTTPS URLs."]
                    )
                }
                let url = try validatedWebURL(value)
                try runOpen(arguments: [url.absoluteString])
                destinationOpened = true
            case "open_chrome_url":
                guard let value = payload["url"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 80,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid Chrome URL."]
                    )
                }
                try openApprovedChromeURL(value)
                destinationOpened = true
            case "close_chrome_tab":
                guard let query = payload["query"] as? String,
                      query.count >= 2, query.count <= 180 else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 134,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid Chrome tab query."]
                    )
                }
                try closeUniqueChromeTab(matching: query)
                destinationOpened = true
            case "quit_app":
                guard let name = payload["name"] as? String,
                      !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 135,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid app quit request."]
                    )
                }
                try quitApplicationNormally(named: name)
            case "move_resize_window":
                guard let target = payload["target"] as? String ?? payload["app"] as? String,
                      let display = payload["display"] as? String,
                      ["current", "mac", "xb283k"].contains(display),
                      let layout = payload["layout"] as? String,
                      [
                        "preserve", "maximize", "center", "left_half", "right_half",
                        "top_half", "bottom_half", "top_left_quarter", "top_right_quarter",
                        "bottom_left_quarter", "bottom_right_quarter", "percent",
                      ].contains(layout) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 136,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid window layout request."]
                    )
                }
                let percent = (payload["percent"] as? NSNumber)?.doubleValue
                try setWindowFrame(
                    target: target,
                    display: display,
                    layout: layout,
                    percent: percent
                )
                destinationOpened = true
            case "open_file":
                guard let path = payload["path"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 54,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid file path."]
                    )
                }
                let url = try safeLocalFileURL(path, mustExist: true)
                try runOpen(arguments: [url.path])
                destinationOpened = true
            case "reveal_file":
                guard let path = payload["path"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 55,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid Finder path."]
                    )
                }
                let url = try safeLocalFileURL(path, mustExist: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                Thread.sleep(forTimeInterval: 0.35)
                destinationOpened = true
            case "copy_to_clipboard":
                guard let text = payload["text"] as? String, !text.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 38,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected empty clipboard text."]
                    )
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 39,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis could not update the clipboard."]
                    )
                }
            case "type_text":
                guard let text = payload["text"] as? String, !text.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 40,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected empty typing text."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try postText(text)
            case "key_combo":
                guard let key = payload["key"] as? String,
                      let modifiers = payload["modifiers"] as? [String] else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 41,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid shortcut."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try postKey(key: key, modifiers: modifiers)
            case "click_ui":
                guard let label = payload["label"] as? String, !label.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 56,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an empty control label."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try pressVisibleControl(label: label)
            case "focus_ui":
                guard let label = payload["label"] as? String, !label.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 70,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an empty field label."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try focusVisibleControl(label: label)
            case "verify_ui":
                guard let label = payload["label"] as? String, !label.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 71,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an empty verification label."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try verifyVisibleControl(label: label)
            case "scroll":
                guard let direction = payload["direction"] as? String,
                      ["up", "down", "left", "right"].contains(direction),
                      let amount = payload["amount"] as? String,
                      ["small", "medium", "large"].contains(amount) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 57,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid scroll action."]
                    )
                }
                if !destinationOpened { activateVoiceTarget() }
                try postScroll(direction: direction, amount: amount)
            case "wait":
                guard let value = payload["seconds"] as? NSNumber,
                      value.doubleValue >= 0.1, value.doubleValue <= 5.0 else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 72,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid wait duration."]
                    )
                }
                Thread.sleep(forTimeInterval: value.doubleValue)
            case "set_tradingview_interval":
                guard let value = payload["minutes"] as? NSNumber else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 85,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid TradingView interval."]
                    )
                }
                try setTradingViewInterval(minutes: value.intValue)
                destinationOpened = true
            case "prepare_tradingview_capture":
                try prepareTradingViewCapture()
                destinationOpened = true
            case "mark_tradingview_ny_range_fib":
                try markTradingViewNYRangeFib()
                destinationOpened = true
            case "send_active_window_to_work":
                guard actionIndex == actions.count - 1,
                      let task = payload["task"] as? String,
                      !task.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 86,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Jarvis rejected an invalid or out-of-order Work handoff."
                        ]
                    )
                }
                guard NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased()
                        == "tradingview" else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 87,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Jarvis refused to send because TradingView was not the active window."
                        ]
                    )
                }
                logVoiceDiagnostic("tradingview_work_handoff_started")
                runDetached(["send", task, "--route", "work"], listening: true)
            case "send_tradingview_review_to_work":
                guard actionIndex == actions.count - 1,
                      let task = payload["task"] as? String,
                      !task.isEmpty,
                      let values = payload["timeframes"] as? [NSNumber] else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 100,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Jarvis rejected an invalid or out-of-order chart review."
                        ]
                    )
                }
                let timeframes = values.map(\.intValue)
                setCaptureInProgress(true)
                defer { setCaptureInProgress(false) }
                let screenshots = try captureTradingViewReview(timeframes: timeframes)
                logVoiceDiagnostic("tradingview_work_handoff_started images=\(screenshots.count)")
                runDetached(
                    ["send", task, "--route", "work", "--screenshots"] + screenshots,
                    listening: true
                )
                destinationOpened = true
            case "create_folder":
                guard let path = payload["path"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 58,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid folder path."]
                    )
                }
                let url = try safeLocalFileURL(path, mustExist: false)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 59,
                        userInfo: [NSLocalizedDescriptionKey: "A file or folder already exists at \(url.path). Nothing was overwritten."]
                    )
                }
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
            case "move_file":
                guard let sourcePath = payload["source"] as? String,
                      let destinationPath = payload["destination"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 60,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid move request."]
                    )
                }
                let source = try safeLocalFileURL(sourcePath, mustExist: true)
                let destination = try safeLocalFileURL(destinationPath, mustExist: false)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 61,
                        userInfo: [NSLocalizedDescriptionKey: "The destination already exists. Nothing was overwritten."]
                    )
                }
                guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 62,
                        userInfo: [NSLocalizedDescriptionKey: "The destination folder does not exist."]
                    )
                }
                try FileManager.default.moveItem(at: source, to: destination)
            case "trash_file":
                guard let path = payload["path"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 63,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid Trash request."]
                    )
                }
                let url = try safeLocalFileURL(path, mustExist: true)
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            case "open_settings":
                guard let pane = payload["pane"] as? String else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 64,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an invalid Settings request."]
                    )
                }
                try openSettingsPane(pane)
                destinationOpened = true
            case "run_shortcut":
                guard let name = payload["name"] as? String, !name.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 65,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an empty Shortcut name."]
                    )
                }
                try runProcess(
                    executable: "/usr/bin/shortcuts",
                    arguments: ["run", name],
                    failureMessage: "The approved Apple Shortcut could not run."
                )
            case "send_message":
                guard let app = payload["app"] as? String,
                      let recipient = payload["recipient"] as? String, !recipient.isEmpty,
                      let text = payload["text"] as? String, !text.isEmpty else {
                    throw NSError(
                        domain: jarvisBundleIdentifier,
                        code: 66,
                        userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an incomplete message."]
                    )
                }
                try sendApprovedMessage(
                    app: app,
                    recipient: recipient,
                    text: text,
                    subject: payload["subject"] as? String ?? ""
                )
            default:
                throw NSError(
                    domain: jarvisBundleIdentifier,
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "Jarvis rejected an unsupported local action."]
                )
            }
            if [
                "open_app", "open_url", "open_chrome_url", "open_file", "reveal_file",
                "close_chrome_tab", "quit_app", "move_resize_window",
                "type_text", "key_combo", "click_ui", "focus_ui", "scroll", "wait",
                "set_tradingview_interval", "prepare_tradingview_capture",
                "mark_tradingview_ny_range_fib", "open_settings",
                "run_shortcut", "send_message",
            ].contains(type) {
                invalidateAccessibilityScene()
            }
            actionSucceeded = true
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Login item approval needed"
            alert.informativeText = (
                "macOS has Jarvis waiting for approval. You can approve it in Login Items "
                + "or disable the pending login item."
            )
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            } else if response == .alertSecondButtonReturn {
                do {
                    try setLoginItemEnabled(false)
                } catch {
                    showAlert(title: "Could not update login setting", message: error.localizedDescription)
                }
            }
            refreshMenuState()
            return
        }

        let enable = service.status != .enabled
        do {
            let status = try setLoginItemEnabled(enable)
            refreshMenuState()
            if status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "Approve Jarvis at login"
                alert.informativeText = (
                    "macOS requires approval in System Settings → General → Login Items."
                )
                alert.addButton(withTitle: "Open Login Items")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showAlert(title: "Could not update login setting", message: error.localizedDescription)
        }
    }

    private func pythonProcess(arguments: [String], capture: Bool = false) -> Process? {
        guard let root = projectPath, !root.isEmpty else {
            showAlert(
                title: "Jarvis is not installed",
                message: "Run bootstrap.command from the Jarvis project folder."
            )
            return nil
        }

        let python = URL(fileURLWithPath: root)
            .appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            showAlert(
                title: "Jarvis environment is missing",
                message: "Run bootstrap.command again."
            )
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-I",
            "-c",
            "import runpy,sys;sys.path.insert(0,sys.argv.pop(1));runpy.run_module('jarvis',run_name='__main__')",
            root,
        ] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "LC_CTYPE": inherited["LC_CTYPE"] ?? "UTF-8",
            "JARVIS_ROOT": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Jarvis").path,
            "JARVIS_DASHBOARD_TOKEN": dashboardToken,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONSAFEPATH": "1",
        ]
        if arguments.first == "dashboard" {
            environment["JARVIS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        }
        process.environment = environment

        if capture {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            let logURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Jarvis/Data/logs/menu-core.log")
            preparePrivateLog(logURL)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                process.standardOutput = handle
                process.standardError = handle
            }
        }
        return process
    }

    private func startServerIfNeeded() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        guard let process = pythonProcess(arguments: ["dashboard"]) else { return }

        do {
            try process.run()
            serverProcess = process
        } catch {
            showAlert(title: "Jarvis could not start", message: error.localizedDescription)
        }
    }

    private func runDetached(_ arguments: [String], listening: Bool = false) {
        guard let process = pythonProcess(arguments: arguments, capture: true) else { return }

        if listening {
            statusItem.button?.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Listening"
            )
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0,
                   let pipe = process.standardOutput as? Pipe {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8) ?? "Jarvis command failed."
                    DispatchQueue.main.async {
                        self.showCommandError(
                            title: "Jarvis command failed",
                            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                } else if process.terminationStatus == 0,
                          arguments.first == "send",
                          let routeIndex = arguments.firstIndex(of: "--route"),
                          arguments.indices.contains(routeIndex + 1),
                          arguments[routeIndex + 1] == "work" {
                    logVoiceDiagnostic("work_handoff_completed")
                }
            } catch {
                DispatchQueue.main.async {
                    self.showCommandError(
                        title: "Jarvis command failed",
                        message: error.localizedDescription
                    )
                }
            }

            self.detachedProcessLock.lock()
            self.detachedProcesses.removeAll { $0 === process }
            self.detachedProcessLock.unlock()
            DispatchQueue.main.async {
                self.updateVoiceStatusIcon()
            }
        }
    }

    @objc private func openDashboard() {
        startServerIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            NSWorkspace.shared.open(self.dashboardURL)
        }
    }

    @objc private func askJarvis() {
        runDetached([
            "send",
            "Analyze the active window and recommend next steps.",
            "--route",
            "auto",
        ], listening: true)
    }

    @objc private func sendToChat() {
        runDetached([
            "send",
            "Analyze the active window and recommend next steps.",
            "--route",
            "chat",
        ], listening: true)
    }

    @objc private func sendToWork() {
        runDetached([
            "send",
            "Analyze the active window and complete the requested work safely.",
            "--route",
            "work",
        ], listening: true)
    }

    @objc private func readScreen() {
        runDetached(["read-active-window"])
    }

    @objc private func runTradingViewReviewDiagnostic() {
        do {
            try openApplication(named: "TradingView")
        } catch {
            showCommandError(
                title: "Jarvis chart review diagnostic failed",
                message: error.localizedDescription
            )
            return
        }
        setCaptureInProgress(true)
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { self.setCaptureInProgress(false) }
            }
            do {
                let paths = try self.captureTradingViewReview(timeframes: [5, 15, 60, 240])
                logVoiceDiagnostic(
                    "tradingview_review_diagnostic_completed images=\(paths.count)"
                )
            } catch {
                logVoiceDiagnostic(
                    "tradingview_review_diagnostic_failed " + errorDiagnostic(error)
                )
                DispatchQueue.main.async {
                    self.showCommandError(
                        title: "Jarvis chart review diagnostic failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @objc private func handleTradingViewReviewDiagnosticRequest(_ notification: Notification) {
        runTradingViewReviewDiagnostic()
    }

    @objc private func runTradingViewNYFibDiagnostic() {
        do {
            try openApplication(named: "TradingView")
        } catch {
            showCommandError(
                title: "Jarvis NY Fib diagnostic failed",
                message: error.localizedDescription
            )
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.markTradingViewNYRangeFib()
                logVoiceDiagnostic("tradingview_ny_fib_diagnostic_completed")
            } catch {
                DispatchQueue.main.async {
                    self.showCommandError(
                        title: "Jarvis NY Fib diagnostic failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @objc private func exportMemory() {
        runDetached(["export-memory"])
    }

    @objc private func checkScreenPermission() {
        if CGPreflightScreenCaptureAccess() {
            showAlert(
                title: "Screen permission granted",
                message: "Jarvis can capture active windows on either monitor."
            )
            return
        }

        _ = CGRequestScreenCaptureAccess()
        showAlert(
            title: "Screen permission required",
            message:
                "Enable Jarvis under System Settings → Privacy & Security → "
                + "Screen & System Audio Recording. Then choose Quit Jarvis and reopen it once."
        )
    }

    @objc private func checkAccessibilityPermission() {
        let axTrusted = AXIsProcessTrusted()
        let eventPosting = CGPreflightPostEventAccess()
        if axTrusted && eventPosting {
            showAlert(
                title: "Accessibility permission granted",
                message: "The running Jarvis app can inspect controls and post approved keyboard input."
            )
            return
        }
        if axTrusted {
            _ = CGRequestPostEventAccess()
            showAlert(
                title: "Accessibility granted",
                message: (
                    "Accessibility control is active. macOS will authorize keyboard-event posting "
                    + "when Jarvis issues the next action you explicitly approve."
                )
            )
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestPostEventAccess()
        showAlert(
            title: "Accessibility approval requested",
            message: (
                "macOS still denies Accessibility control. Approve the macOS prompt, then choose "
                + "Quit Jarvis and reopen it once."
            )
        )
    }

    @objc private func restartCore() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        startServerIfNeeded()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showCommandError(title: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jarvis/Data/logs/menu-errors.log")
        let record = "[\(timestamp)] \(title)\n\(message)\n\n"
        preparePrivateLog(logURL)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(record.utf8))
            try? handle.close()
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy Error")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }
    }

    @objc private func quitJarvis() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = JarvisMenuController()
application.delegate = delegate
application.run()
