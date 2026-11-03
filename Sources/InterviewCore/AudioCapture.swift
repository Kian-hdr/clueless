import Foundation
import AVFoundation
import CoreAudio
import OSLog

public enum AudioCaptureError: LocalizedError {
    case unsupportedSystem, microphoneDenied, invalidFormat, operation(String, OSStatus), conversion(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "System audio requires macOS 14.2 or later."
        case .microphoneDenied: return "Microphone access is required. Enable Interview Assistant in System Settings > Privacy & Security > Microphone, then start again."
        case .invalidFormat: return "The selected audio device has no usable audio format. Connect an input/output device and start again."
        case .operation(let name, let status): return "\(name) failed (Core Audio \(status)). Check System Settings > Privacy & Security > Screen & System Audio Recording and audio devices, then start again."
        case .conversion(let description): return "Audio conversion failed: \(description)"
        }
    }
}

/// Serial-use converter. Each capture source owns one encoder on its audio callback queue.
/// Output is mono little-endian PCM16, 16 kHz, 800 frames / 50 ms per chunk.
final class PCM16ChunkEncoder {
    private let role: AudioRole
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var remainder = Data()
    private var remainderTime: Date?
    var pendingByteCount: Int { remainder.count }

    init(format: AVAudioFormat, role: AudioRole) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { throw AudioCaptureError.invalidFormat }
        self.role = role
        self.outputFormat = output
        if format == output { converter = nil }
        else {
            guard let created = AVAudioConverter(from: format, to: output) else { throw AudioCaptureError.invalidFormat }
            created.primeMethod = .none
            converter = created
        }
    }

    func append(_ input: AVAudioPCMBuffer, at date: Date = Date()) throws -> [AudioChunk] {
        guard input.frameLength > 0 else { return [] }
        let converted: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw AudioCaptureError.invalidFormat }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if provided { state.pointee = .noDataNow; return nil }
                provided = true
                state.pointee = .haveData
                return input
            }
            if let error { throw AudioCaptureError.conversion(error.localizedDescription) }
            if status == .error { throw AudioCaptureError.conversion("The audio device format changed. Stop and start capture.") }
            converted = output
        } else { converted = input }
        guard let floats = converted.floatChannelData?[0] else { throw AudioCaptureError.invalidFormat }
        var samples = [Int16](repeating: 0, count: Int(converted.frameLength))
        for i in samples.indices {
            let f = floats[i]
            samples[i] = f.isFinite ? Int16((min(1, max(-1, f)) * Float(Int16.max)).rounded()).littleEndian : 0
        }
        if remainder.isEmpty { remainderTime = date }
        samples.withUnsafeBytes { remainder.append(contentsOf: $0) }
        var chunks: [AudioChunk] = []
        var consumed = 0
        while remainder.count - consumed >= 1600 {
            let start = remainder.startIndex + consumed
            chunks.append(AudioChunk(role: role, pcm16: remainder.subdata(in: start..<(start + 1600)), capturedAt: remainderTime ?? date))
            consumed += 1600
            remainderTime = (remainderTime ?? date).addingTimeInterval(0.05)
        }
        if consumed > 0 { remainder = Data(remainder.dropFirst(consumed)) }
        return chunks
    }
}

enum CaptureDelivery: Sendable {
    case audio(AudioChunk, Float)
    case error(String)
}

/// Audio callbacks may start synchronously while AVAudioEngine.prepare/start
/// still blocks the main actor. That warmup is outside the listening session:
/// no samples are converted, retained, or sent until BOTH sources are ready.
/// NSLock protects only this small state machine and nonblocking stream yields.
/// Every start owns a new gate; a closed gate can never be armed again.
final class CaptureDeliveryGate: @unchecked Sendable {
    private enum State { case warming, armed, closed }
    let stream: AsyncStream<CaptureDelivery>
    private let sink: AsyncStream<CaptureDelivery>.Continuation
    private let lock = NSLock()
    private var state = State.warming
    private var warmupCallbacks = 0
    private var overflows = 0

    init(capacity: Int = 20) {
        var continuation: AsyncStream<CaptureDelivery>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(max(1, capacity))) { continuation = $0 }
        sink = continuation
    }

    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return state == .armed }
    var warmupCallbackCount: Int { lock.lock(); defer { lock.unlock() }; return warmupCallbacks }
    var overflowCount: Int { lock.lock(); defer { lock.unlock() }; return overflows }

    func beginAudioBuffer() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .warming: warmupCallbacks += 1; return false
        case .armed: return true
        case .closed: return false
        }
    }

    @discardableResult func arm() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .warming else { return state == .armed }
        state = .armed
        return true
    }

    func submit(_ chunk: AudioChunk, level: Float) {
        lock.lock(); defer { lock.unlock() }
        guard state == .armed else { return }
        if case .dropped = sink.yield(.audio(chunk, level)) {
            overflows += 1
            failLocked("Audio processing fell behind. Capture stopped rather than silently dropping conversation audio. Start the session again.")
        }
    }

    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard state != .closed else { return }
        failLocked(message)
    }

    private func failLocked(_ message: String) {
        state = .closed
        // bufferNewest guarantees the terminal error survives even when the
        // bounded queue is full. Finish rejects all later source callbacks.
        sink.yield(.error(message)); sink.finish()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        sink.finish()
    }
}

public struct AudioStartupDiagnostics: Sendable {
    public let systemStartMilliseconds: Double
    public let microphoneStartMilliseconds: Double
    public let totalStartMilliseconds: Double
    public let ignoredWarmupCallbacks: Int
}

/// Owns all HAL/AVAudioEngine lifecycle state on the main actor. Audio callbacks
/// synchronously convert their own buffers and yield to a bounded stream; they do
/// not create an unbounded DispatchQueue backlog or retain borrowed HAL pointers.
@MainActor
public final class AudioCaptureController {
    public var onChunk: ((AudioChunk) -> Void)?
    public var onLevel: ((AudioRole, Float) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var isRunning = false
    public private(set) var startupDiagnostics: AudioStartupDiagnostics?
    private var engine: AVAudioEngine?
    private var streamTask: Task<Void, Never>?
    private var deliveryGate: CaptureDeliveryGate?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var configurationObserver: NSObjectProtocol?
    private let systemQueue = DispatchQueue(label: "InterviewAssistant.systemAudio", qos: .userInteractive)
    private var generation: UInt64 = 0
    private static let logger = Logger(subsystem: "com.kiankonrad.Clueless", category: "AudioCapture")

    public init() {}

    public func start() async throws {
        if isRunning { return }
        guard #available(macOS 14.2, *) else { throw AudioCaptureError.unsupportedSystem }
        generation &+= 1
        let current = generation
        let authorized = await AVCaptureDevice.requestAccess(for: .audio)
        guard current == generation else { throw CancellationError() }
        guard authorized else { throw AudioCaptureError.microphoneDenied }

        startupDiagnostics = nil
        let gate = CaptureDeliveryGate()
        deliveryGate = gate
        streamTask = Task { [weak self] in
            for await event in gate.stream {
                guard let self, current == self.generation, !Task.isCancelled else { break }
                switch event {
                case .audio(let chunk, let level): self.onChunk?(chunk); self.onLevel?(chunk.role, level)
                case .error(let message): self.onError?(message); self.stop(); return
                }
            }
        }
        let startupBegan = DispatchTime.now().uptimeNanoseconds
        do {
            try startSystemAudio(gate: gate)
            let systemReady = DispatchTime.now().uptimeNanoseconds
            try startMicrophone(gate: gate)
            let microphoneReady = DispatchTime.now().uptimeNanoseconds
            guard current == generation, !Task.isCancelled else { throw CancellationError() }
            let diagnostics = AudioStartupDiagnostics(
                systemStartMilliseconds: Double(systemReady - startupBegan) / 1_000_000,
                microphoneStartMilliseconds: Double(microphoneReady - systemReady) / 1_000_000,
                totalStartMilliseconds: Double(microphoneReady - startupBegan) / 1_000_000,
                ignoredWarmupCallbacks: gate.warmupCallbackCount
            )
            startupDiagnostics = diagnostics
            Self.logger.info("Capture ready: system=\(diagnostics.systemStartMilliseconds, privacy: .public)ms microphone=\(diagnostics.microphoneStartMilliseconds, privacy: .public)ms total=\(diagnostics.totalStartMilliseconds, privacy: .public)ms ignoredWarmupCallbacks=\(diagnostics.ignoredWarmupCallbacks, privacy: .public)")
            // Arm only after native startup and diagnostic logging are done.
            // No await or native startup follows; the main actor can return to
            // the session and drain callbacks immediately.
            guard gate.arm() else { throw AudioCaptureError.conversion("An audio source changed during startup. Start the session again.") }
            isRunning = true
        } catch {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startupBegan) / 1_000_000
            Self.logger.error("Capture startup failed after \(elapsed, privacy: .public)ms; ignoredWarmupCallbacks=\(gate.warmupCallbackCount, privacy: .public)")
            stop()
            throw error
        }
    }

    public func stop() {
        generation &+= 1
        isRunning = false
        // Close before removing taps: late callbacks cannot enter a later
        // session, and no delivery is queued while HAL/engine teardown blocks.
        deliveryGate?.close(); deliveryGate = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        if let proc = ioProcID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
        }
        ioProcID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID); deviceID = AudioObjectID(kAudioObjectUnknown) }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        streamTask?.cancel(); streamTask = nil
    }

    private func startMicrophone(gate: CaptureDeliveryGate) throws {
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let encoder = try PCM16ChunkEncoder(format: format, role: .you)
        let callback: AVAudioNodeTapBlock = { buffer, _ in
            Self.encode(buffer, encoder: encoder, gate: gate)
        }
        if #available(macOS 27.0, *) {
            // The SDK's refined throwing import preserves a unit-valued error
            // parameter until AVFAudio supplies its Swift overlay convenience.
            try input.__installTap(onBus: 0, bufferSize: 1024, format: format, error: (), block: callback)
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: callback)
        }
        engine = newEngine
        newEngine.prepare()
        try newEngine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: nil) { _ in
            gate.fail("The microphone audio configuration changed. Stop and start the interview session to reinitialize capture.")
        }
    }

    @available(macOS 14.2, *)
    private func startSystemAudio(gate: CaptureDeliveryGate) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Interview Assistant call audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read system audio format")
        guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.invalidFormat }
        let encoder = try PCM16ChunkEncoder(format: format, role: .interviewer)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Interview Assistant private capture",
            kAudioAggregateDeviceUIDKey: "interview-assistant-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Create system audio device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, systemQueue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            Self.encode(buffer, encoder: encoder, gate: gate)
        }, "Register system audio callback")
        try check(AudioDeviceStart(deviceID, ioProcID), "Start system audio")
    }

    nonisolated private static func encode(_ buffer: AVAudioPCMBuffer, encoder: PCM16ChunkEncoder, gate: CaptureDeliveryGate) {
        guard gate.beginAudioBuffer() else { return }
        do {
            for chunk in try encoder.append(buffer) {
                let level: Float = chunk.pcm16.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Int16.self)
                    guard !samples.isEmpty else { return 0 }
                    let mean = samples.reduce(Float(0)) { total, sample in let value = Float(sample) / Float(Int16.max); return total + value * value } / Float(samples.count)
                    return sqrt(mean)
                }
                gate.submit(chunk, level: level)
                if !gate.isArmed { return }
            }
        } catch { gate.fail(error.localizedDescription) }
    }

    private func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else { throw AudioCaptureError.operation(name, status) }
    }
}
