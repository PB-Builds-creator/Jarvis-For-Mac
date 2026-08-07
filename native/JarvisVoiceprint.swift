import AVFoundation
import CoreML
import Foundation

private enum VoiceprintError: LocalizedError {
    case usage
    case audioUnavailable
    case audioTooShort
    case audioTooQuiet
    case invalidModelOutput

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: jarvis-voiceprint extract <model.mlmodelc> <audio-file>"
        case .audioUnavailable:
            return "The voice sample could not be decoded."
        case .audioTooShort:
            return "Speak naturally for at least one second."
        case .audioTooQuiet:
            return "The voice sample was too quiet or contained too little speech."
        case .invalidModelOutput:
            return "The local speaker model returned an invalid embedding."
        }
    }
}

private func writeJSON(_ payload: [String: Any], exitCode: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    ) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    Foundation.exit(exitCode)
}

private func fail(_ error: Error) -> Never {
    writeJSON(
        ["ok": false, "error": error.localizedDescription],
        exitCode: 1
    )
}

private func loadMono16kAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    guard sourceFormat.sampleRate > 0,
          sourceFormat.channelCount > 0,
          file.length > 0 else {
        throw VoiceprintError.audioUnavailable
    }
    let sourceCapacity = AVAudioFrameCount(min(file.length, 60 * Int64(sourceFormat.sampleRate)))
    guard let source = AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: sourceCapacity
    ) else {
        throw VoiceprintError.audioUnavailable
    }
    try file.read(into: source, frameCount: sourceCapacity)

    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
        throw VoiceprintError.audioUnavailable
    }
    let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(
        max(1, ceil(Double(source.frameLength) * ratio) + 256)
    )
    guard let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
    ) else {
        throw VoiceprintError.audioUnavailable
    }
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
    if status == .error {
        throw conversionError ?? VoiceprintError.audioUnavailable
    }
    guard let channel = output.floatChannelData?[0] else {
        throw VoiceprintError.audioUnavailable
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

private struct PreparedAudio {
    let samples: [Float]
    let voicedSeconds: Double
    let peakDB: Double
    let pitchHz: Double
    let pitchSpread: Double
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(
        sorted.count - 1,
        max(0, Int((Double(sorted.count - 1) * fraction).rounded()))
    )
    return sorted[index]
}

private func pitchStatistics(_ samples: [Float]) -> (Double, Double) {
    // Pitch is a secondary regular-voice style check. Downsample to 8 kHz and
    // inspect 40 ms windows so it stays far cheaper than model inference.
    let source = samples.prefix(64_000)
    var downsampled: [Float] = []
    downsampled.reserveCapacity(source.count / 2)
    var sourceIndex = source.startIndex
    while sourceIndex < source.endIndex {
        let next = source.index(after: sourceIndex)
        if next < source.endIndex {
            downsampled.append((source[sourceIndex] + source[next]) * 0.5)
            sourceIndex = source.index(after: next)
        } else {
            downsampled.append(source[sourceIndex])
            break
        }
    }
    let window = 320
    let hop = 320
    guard downsampled.count >= window else { return (0, 0) }
    var pitches: [Double] = []
    var start = 0
    while start + window <= downsampled.count {
        let rawFrame = Array(downsampled[start..<(start + window)])
        let mean = rawFrame.reduce(0.0) { $0 + Double($1) } / Double(window)
        let frame = rawFrame.map { Double($0) - mean }
        let energy = frame.reduce(0.0) { $0 + ($1 * $1) } / Double(window)
        if energy > 1e-6 {
            // YIN's cumulative mean-normalized difference avoids the common
            // zero-lag/harmonic error that previously pinned profiles to the
            // detector's 400 Hz ceiling.
            let minimumLag = 25  // 320 Hz
            let maximumLag = 133 // about 60 Hz
            var differences = [Double](repeating: 0, count: maximumLag + 1)
            for lag in minimumLag...maximumLag {
                for offset in 0..<(window - lag) {
                    let delta = frame[offset] - frame[offset + lag]
                    differences[lag] += delta * delta
                }
            }
            var cumulative = 0.0
            var normalized = [Double](repeating: 1, count: maximumLag + 1)
            for lag in 1...maximumLag {
                cumulative += differences[lag]
                if cumulative > 1e-12 {
                    normalized[lag] = differences[lag] * Double(lag) / cumulative
                }
            }
            var selectedLag: Int?
            for lag in minimumLag..<maximumLag where normalized[lag] < 0.20 {
                if normalized[lag] <= normalized[lag + 1] {
                    selectedLag = lag
                    break
                }
            }
            if selectedLag == nil {
                let bestLag = (minimumLag...maximumLag).min {
                    normalized[$0] < normalized[$1]
                }
                if let bestLag, normalized[bestLag] <= 0.32 {
                    selectedLag = bestLag
                }
            }
            if let selectedLag {
                pitches.append(8_000.0 / Double(selectedLag))
            }
        }
        start += hop
    }
    guard pitches.count >= 3 else { return (0, 0) }
    let median = percentile(pitches, 0.5)
    let spread = percentile(pitches, 0.75) - percentile(pitches, 0.25)
    return (median, spread)
}

private func prepareAudio(_ raw: [Float]) throws -> PreparedAudio {
    let frameSize = 320
    guard raw.count >= 16_000 else { throw VoiceprintError.audioTooShort }
    var frameRMS: [Double] = []
    var frameStart = 0
    while frameStart < raw.count {
        let end = min(raw.count, frameStart + frameSize)
        var sum = 0.0
        for index in frameStart..<end {
            sum += Double(raw[index] * raw[index])
        }
        frameRMS.append(sqrt(sum / Double(max(1, end - frameStart))))
        frameStart += frameSize
    }
    let peakRMS = frameRMS.max() ?? 0
    guard peakRMS >= 0.006 else { throw VoiceprintError.audioTooQuiet }
    let noiseRMS = percentile(frameRMS, 0.20)
    let threshold = max(0.004, min(peakRMS * 0.24, noiseRMS * 3.5 + 0.002))
    let activeFrames = frameRMS.indices.filter { frameRMS[$0] >= threshold }
    guard activeFrames.count >= 30,
          let first = activeFrames.first,
          let last = activeFrames.last else {
        throw VoiceprintError.audioTooQuiet
    }
    let paddingFrames = 8
    var firstFrame = max(0, first - paddingFrames)
    var lastFrame = min(frameRMS.count - 1, last + paddingFrames)

    // A television or podcast can keep nearly every frame "active" and dilute
    // the near-field owner's voiceprint. In that specific case, select the
    // strongest contiguous 3.2-second foreground window. The threshold and
    // identity score remain unchanged; this removes quieter room speech rather
    // than weakening the owner-only gate.
    let activeRatio = Double(activeFrames.count) / Double(max(1, frameRMS.count))
    let activeLevels = activeFrames.map { frameRMS[$0] }
    let foregroundContrast = percentile(activeLevels, 0.85)
        / max(0.000_001, percentile(activeLevels, 0.30))
    let foregroundWindowFrames = 160
    if frameRMS.count > foregroundWindowFrames,
       activeRatio >= 0.72,
       foregroundContrast >= 1.35 {
        var bestStart = firstFrame
        var bestScore = -Double.infinity
        for start in 0...(frameRMS.count - foregroundWindowFrames) {
            var score = 0.0
            for level in frameRMS[start..<(start + foregroundWindowFrames)] {
                let foreground = max(0, level - threshold)
                score += foreground * foreground
            }
            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }
        firstFrame = bestStart
        lastFrame = bestStart + foregroundWindowFrames - 1
    }
    let firstSample = firstFrame * frameSize
    let lastSample = min(raw.count, (lastFrame + 1) * frameSize)
    var trimmed = Array(raw[firstSample..<lastSample])
    guard trimmed.count >= 12_000 else { throw VoiceprintError.audioTooShort }
    if trimmed.count > 160_000 {
        trimmed = Array(trimmed.prefix(160_000))
    }
    let peak = trimmed.reduce(Float(0)) { max($0, abs($1)) }
    guard peak >= 0.01 else { throw VoiceprintError.audioTooQuiet }
    let gain = min(8.0, 0.80 / peak)
    if gain > 1 {
        for index in trimmed.indices {
            trimmed[index] = max(-1, min(1, trimmed[index] * gain))
        }
    }
    let pitch = pitchStatistics(trimmed)
    return PreparedAudio(
        samples: trimmed,
        voicedSeconds: Double(activeFrames.count * frameSize) / 16_000.0,
        peakDB: 20.0 * log10(max(Double(peak), 1e-9)),
        pitchHz: pitch.0,
        pitchSpread: pitch.1
    )
}

private func makeMultiArray(shape: [NSNumber]) throws -> MLMultiArray {
    try MLMultiArray(shape: shape, dataType: .float32)
}

final class JarvisVoiceprintModel: @unchecked Sendable {
    private let model: MLModel

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    func extract(audioURL: URL) throws -> [String: Any] {
        try extractVoiceprint(model: model, audioURL: audioURL)
    }
}

private func extractVoiceprint(
    model: MLModel,
    audioURL: URL
) throws -> [String: Any] {
    let startedAt = Date()
    let prepared = try prepareAudio(loadMono16kAudio(audioURL))
    let preparedAt = Date()
    let waveform = try makeMultiArray(shape: [3, 160_000])
    let mask = try makeMultiArray(shape: [3, 589])
    let waveformPointer = waveform.dataPointer.bindMemory(
        to: Float.self,
        capacity: waveform.count
    )
    let maskPointer = mask.dataPointer.bindMemory(
        to: Float.self,
        capacity: mask.count
    )
    waveformPointer.initialize(repeating: 0, count: waveform.count)
    maskPointer.initialize(repeating: 0, count: mask.count)

    var destination = 0
    while destination < 160_000 {
        let copyCount = min(prepared.samples.count, 160_000 - destination)
        prepared.samples.withUnsafeBufferPointer { source in
            guard let sourceAddress = source.baseAddress else { return }
            waveformPointer.advanced(by: destination).update(
                from: sourceAddress,
                count: copyCount
            )
        }
        destination += copyCount
    }
    for index in 0..<589 {
        maskPointer[index] = 1
    }

    let provider = try MLDictionaryFeatureProvider(dictionary: [
        "waveform": MLFeatureValue(multiArray: waveform),
        "mask": MLFeatureValue(multiArray: mask),
    ])
    let result = try model.prediction(from: provider)
    let inferredAt = Date()
    guard let output = result.featureValue(for: "embedding")?.multiArrayValue,
          output.count >= 256 else {
        throw VoiceprintError.invalidModelOutput
    }
    let outputPointer = output.dataPointer.bindMemory(
        to: Float.self,
        capacity: output.count
    )
    var embedding = Array(
        UnsafeBufferPointer(start: outputPointer, count: 256)
    )
    let magnitude = sqrt(embedding.reduce(0.0) { $0 + Double($1 * $1) })
    guard magnitude.isFinite, magnitude > 1e-6 else {
        throw VoiceprintError.invalidModelOutput
    }
    for index in embedding.indices {
        embedding[index] /= Float(magnitude)
    }
    return [
        "ok": true,
        "embedding": embedding,
        "duration_seconds": Double(prepared.samples.count) / 16_000.0,
        "voiced_seconds": prepared.voicedSeconds,
        "peak_db": prepared.peakDB,
        "pitch_hz": prepared.pitchHz,
        "pitch_spread": prepared.pitchSpread,
        "model_compute": "cpu_and_neural_engine",
        "latency_ms": [
            "audio_and_features": Int(
                preparedAt.timeIntervalSince(startedAt) * 1_000
            ),
            "model_load": Int(
                0
            ),
            "inference": Int(
                inferredAt.timeIntervalSince(preparedAt) * 1_000
            ),
            "total": Int(
                inferredAt.timeIntervalSince(startedAt) * 1_000
            ),
        ],
    ]
}

#if !JARVIS_APP
@main
private struct JarvisVoiceprintCLI {
    static func main() {
        guard CommandLine.arguments.count >= 4,
              ["extract", "extract-batch"].contains(CommandLine.arguments[1])
        else {
            fail(VoiceprintError.usage)
        }
        do {
            let model = try JarvisVoiceprintModel(
                modelURL: URL(fileURLWithPath: CommandLine.arguments[2])
            )
            if CommandLine.arguments[1] == "extract" {
                guard CommandLine.arguments.count == 4 else {
                    fail(VoiceprintError.usage)
                }
                writeJSON(try model.extract(
                    audioURL: URL(fileURLWithPath: CommandLine.arguments[3])
                ))
            }
            let samples = try CommandLine.arguments.dropFirst(3).map {
                try model.extract(audioURL: URL(fileURLWithPath: $0))
            }
            writeJSON(["ok": true, "samples": samples])
        } catch {
            fail(error)
        }
    }
}
#endif
