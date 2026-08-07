import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Vision
import Speech
import AVFoundation
import Darwin

let helperVersion = "1.0.0"

func emit(_ object: Any, exitCode: Int32 = 0) -> Never {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("JSON output failed: \(error)\n".utf8))
        exit(2)
    }
    exit(exitCode)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func argument(_ index: Int, default fallback: String? = nil) -> String {
    if CommandLine.arguments.count > index {
        return CommandLine.arguments[index]
    }
    if let fallback { return fallback }
    fail("Missing argument at position \(index).")
}

func trusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func frontmostApplication() -> NSRunningApplication? {
    return NSWorkspace.shared.frontmostApplication
}

func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    return error == .success ? value : nil
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    guard let value = axValue(element, attribute) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    guard let raw = axValue(element, kAXChildrenAttribute as CFString) else { return [] }
    return raw as? [AXUIElement] ?? []
}

func actionNames(of element: AXUIElement) -> [String] {
    var raw: CFArray?
    let error = AXUIElementCopyActionNames(element, &raw)
    guard error == .success, let array = raw as? [String] else { return [] }
    return array
}

func elementInfo(_ element: AXUIElement) -> [String: Any] {
    let role = axString(element, kAXRoleAttribute as CFString) ?? ""
    let subrole = axString(element, kAXSubroleAttribute as CFString) ?? ""
    let title = axString(element, kAXTitleAttribute as CFString) ?? ""
    let description = axString(element, kAXDescriptionAttribute as CFString) ?? ""
    let value = axString(element, kAXValueAttribute as CFString) ?? ""
    let identifier = axString(element, kAXIdentifierAttribute as CFString) ?? ""
    var result: [String: Any] = [
        "role": role,
        "subrole": subrole,
        "title": title,
        "description": description,
        "value": value,
        "identifier": identifier,
        "actions": actionNames(of: element),
    ]
    if let position = axPoint(element, kAXPositionAttribute as CFString) {
        result["x"] = Double(position.x)
        result["y"] = Double(position.y)
    }
    if let size = axSize(element, kAXSizeAttribute as CFString) {
        result["width"] = Double(size.width)
        result["height"] = Double(size.height)
    }
    return result
}

func searchableText(_ info: [String: Any]) -> String {
    return ["role", "subrole", "title", "description", "value", "identifier"]
        .compactMap { info[$0] as? String }
        .joined(separator: " ")
        .lowercased()
}

func focusedAppElement() -> (NSRunningApplication, AXUIElement) {
    guard trusted(prompt: false) else {
        fail("Accessibility permission is not granted. Open Jarvis permissions and enable Accessibility.")
    }
    guard let app = frontmostApplication() else { fail("No frontmost application was found.") }
    return (app, AXUIElementCreateApplication(app.processIdentifier))
}

func findElements(query: String, limit: Int) -> [[String: Any]] {
    let (_, root) = focusedAppElement()
    let needle = query.lowercased()
    var results: [[String: Any]] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    let maxNodes = 2500
    while index < queue.count && index < maxNodes && results.count < limit {
        let (element, depth) = queue[index]
        index += 1
        let info = elementInfo(element)
        if searchableText(info).contains(needle) {
            var match = info
            match["depth"] = depth
            results.append(match)
        }
        if depth < 12 {
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
    }
    return results
}

func firstMatchingElement(query: String) -> AXUIElement? {
    let (_, root) = focusedAppElement()
    let needle = query.lowercased()
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    while index < queue.count && index < 2500 {
        let (element, depth) = queue[index]
        index += 1
        if searchableText(elementInfo(element)).contains(needle) {
            return element
        }
        if depth < 12 {
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
    }
    return nil
}

func mouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        fail("Could not create a mouse event.")
    }
    event.post(tap: .cghidEventTap)
}

func performClick(x: Double, y: Double, buttonName: String, count: Int) {
    let point = CGPoint(x: x, y: y)
    let button: CGMouseButton = buttonName.lowercased() == "right" ? .right : .left
    let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    for current in 1...max(1, count) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            fail("Could not create click events.")
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(current))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(current))
        down.post(tap: .cghidEventTap)
        usleep(45_000)
        up.post(tap: .cghidEventTap)
        usleep(80_000)
    }
}


func frontmostNormalWindowInfo() -> [String: Any] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        fail("Could not read the macOS window list.")
    }

    let ignoredOwners: Set<String> = [
        "Jarvis",
        "JarvisMenuBar",
        "Dock",
        "Window Server",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
    ]

    for info in windows {
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        guard layer == 0 else { continue }

        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard !ignoredOwners.contains(owner) else { continue }

        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard alpha > 0.01 else { continue }

        guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        let title = info[kCGWindowName as String] as? String ?? ""

        var result: [String: Any] = [
            "window_id": number.uint32Value,
            "owner": owner,
            "pid": pid,
            "title": title,
            "layer": layer,
        ]

        if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
            result["bounds"] = bounds
        }
        return result
    }

    fail("No normal frontmost application window was found.")
}

func recognizeText(path: String) {
    guard let image = NSImage(contentsOfFile: path) else { fail("Could not open image: \(path)") }
    var proposed = CGRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
        fail("Could not convert the image for OCR.")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) {
        request.automaticallyDetectsLanguage = true
    }
    do {
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    } catch {
        fail("OCR failed: \(error.localizedDescription)")
    }
    let observations = request.results ?? []
    let items: [[String: Any]] = observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return [
            "text": candidate.string,
            "confidence": Double(candidate.confidence),
            "x": Double(box.origin.x),
            "y": Double(box.origin.y),
            "width": Double(box.size.width),
            "height": Double(box.size.height),
        ]
    }
    emit(["items": items, "count": items.count])
}


final class AuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    func set(_ value: SFSpeechRecognizerAuthorizationStatus) { lock.lock(); status = value; lock.unlock() }
    func get() -> SFSpeechRecognizerAuthorizationStatus { lock.lock(); defer { lock.unlock() }; return status }
}

final class ListenState: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _lastUpdate = Date()
    private var _finished = false
    private var _error: String?

    func update(text: String, final: Bool) {
        lock.lock()
        if !text.isEmpty {
            _text = text
            _lastUpdate = Date()
        }
        if final { _finished = true }
        lock.unlock()
    }

    func setError(_ error: String) {
        lock.lock(); _error = error; _finished = true; lock.unlock()
    }

    func snapshot() -> (String, Date, Bool, String?) {
        lock.lock(); defer { lock.unlock() }
        return (_text, _lastUpdate, _finished, _error)
    }
}

func listenForSpeech(silenceMS: Int, maxSeconds: Int) {
    let semaphore = DispatchSemaphore(value: 0)
    let authorization = AuthorizationState()
    SFSpeechRecognizer.requestAuthorization { status in
        authorization.set(status)
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)
    guard authorization.get() == .authorized else {
        fail("Speech Recognition permission was not granted.")
    }

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
        fail("English speech recognition is unavailable.")
    }
    guard recognizer.isAvailable else { fail("Speech recognition is currently unavailable.") }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition {
        request.requiresOnDeviceRecognition = true
    }

    let state = ListenState()
    let audioEngine = AVAudioEngine()
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
    }

    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
            state.update(text: result.bestTranscription.formattedString, final: result.isFinal)
        }
        if let error {
            let snapshot = state.snapshot()
            if snapshot.0.isEmpty { state.setError(error.localizedDescription) }
        }
    }

    do {
        audioEngine.prepare()
        try audioEngine.start()
    } catch {
        input.removeTap(onBus: 0)
        task.cancel()
        fail("Microphone could not start: \(error.localizedDescription)")
    }

    let started = Date()
    let silence = Double(max(400, silenceMS)) / 1000.0
    while Date().timeIntervalSince(started) < Double(max(5, maxSeconds)) {
        let snapshot = state.snapshot()
        if snapshot.2 { break }
        if !snapshot.0.isEmpty && Date().timeIntervalSince(snapshot.1) >= silence { break }
        Thread.sleep(forTimeInterval: 0.1)
    }

    audioEngine.stop()
    input.removeTap(onBus: 0)
    request.endAudio()
    Thread.sleep(forTimeInterval: 0.25)
    task.cancel()

    let snapshot = state.snapshot()
    if snapshot.0.isEmpty {
        fail(snapshot.3 ?? "No speech was recognized.")
    }
    emit(["text": snapshot.0])
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "version"

switch command {
case "version":
    emit(["version": helperVersion])
case "check-accessibility":
    let prompt = argument(2, default: "false").lowercased() == "true"
    emit(["trusted": trusted(prompt: prompt)])
case "focused-app":
    guard let app = frontmostApplication() else { fail("No frontmost app.") }
    emit(["name": app.localizedName ?? "", "bundle_id": app.bundleIdentifier ?? "", "pid": Int(app.processIdentifier)])
case "screen-size":
    let screens = NSScreen.screens.enumerated().map { index, screen in
        ["index": index, "x": Double(screen.frame.origin.x), "y": Double(screen.frame.origin.y), "width": Double(screen.frame.width), "height": Double(screen.frame.height)] as [String: Any]
    }
    emit(["screens": screens])
case "mouse-position":
    let point = CGEvent(source: nil)?.location ?? .zero
    emit(["x": Double(point.x), "y": Double(point.y)])
case "move-mouse":
    let x = Double(argument(2)) ?? 0
    let y = Double(argument(3)) ?? 0
    mouseEvent(type: .mouseMoved, point: CGPoint(x: x, y: y), button: .left)
    emit(["ok": true, "x": x, "y": y])
case "click":
    let x = Double(argument(2)) ?? 0
    let y = Double(argument(3)) ?? 0
    let button = argument(4, default: "left")
    let count = Int(argument(5, default: "1")) ?? 1
    performClick(x: x, y: y, buttonName: button, count: count)
    emit(["ok": true])
case "scroll":
    let dx = Int32(argument(2, default: "0")) ?? 0
    let dy = Int32(argument(3, default: "-600")) ?? -600
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
        fail("Could not create a scroll event.")
    }
    event.post(tap: .cghidEventTap)
    emit(["ok": true, "dx": Int(dx), "dy": Int(dy)])
case "frontmost-window":
    emit(frontmostNormalWindowInfo())
case "list-windows":
    let (app, root) = focusedAppElement()
    let windows = (axValue(root, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []).map(elementInfo)
    emit(["application": app.localizedName ?? "", "windows": windows])
case "find-ui":
    let query = argument(2)
    let limit = Int(argument(3, default: "20")) ?? 20
    emit(["matches": findElements(query: query, limit: max(1, min(limit, 100)))])
case "press-ui":
    let query = argument(2)
    guard let element = firstMatchingElement(query: query) else { fail("No accessible UI element matched '\(query)'.") }
    let info = elementInfo(element)
    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard error == .success else { fail("The matching element does not support a press action (AX error \(error.rawValue)).") }
    emit(["ok": true, "element": info])
case "ocr":
    recognizeText(path: argument(2))
case "listen":
    let silence = Int(argument(2, default: "850")) ?? 850
    let maximum = Int(argument(3, default: "45")) ?? 45
    listenForSpeech(silenceMS: silence, maxSeconds: maximum)
default:
    fail("Unknown native command: \(command)")
}
