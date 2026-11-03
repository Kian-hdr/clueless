import XCTest
import AVFoundation
@testable import InterviewCore

final class AudioCaptureTests: XCTestCase {
    func testWarmupGateDoesNotFillDeliveryQueueBeforeBothSourcesAreReady() async throws {
        let gate = CaptureDeliveryGate(capacity: 2)
        let chunk = AudioChunk(role: .interviewer, pcm16: Data(repeating: 0, count: 1600))
        for _ in 0..<100 {
            if gate.beginAudioBuffer() { gate.submit(chunk, level: 0) }
        }
        XCTAssertEqual(gate.warmupCallbackCount, 100)
        XCTAssertFalse(gate.isArmed)
        gate.arm()
        XCTAssertTrue(gate.beginAudioBuffer())
        gate.submit(chunk, level: 0.25)
        gate.close()
        var received: [CaptureDelivery] = []
        for await event in gate.stream { received.append(event) }
        XCTAssertEqual(received.count, 1)
        guard case .audio(let delivered, let level) = received[0] else { return XCTFail("Warmup must not produce an overflow error") }
        XCTAssertEqual(delivered.role, .interviewer)
        XCTAssertEqual(level, 0.25)
    }

    func testWarmupGateStillFailsClosedOnRealPostReadinessOverflow() async throws {
        let gate = CaptureDeliveryGate(capacity: 2)
        let chunk = AudioChunk(role: .you, pcm16: Data(repeating: 0, count: 1600))
        gate.arm()
        for _ in 0..<10 { gate.submit(chunk, level: 0.1) }
        XCTAssertFalse(gate.isArmed)
        XCTAssertEqual(gate.overflowCount, 1)
        var received: [CaptureDelivery] = []
        for await event in gate.stream { received.append(event) }
        XCTAssertLessThanOrEqual(received.count, 2)
        XCTAssertTrue(received.contains { if case .error(let text) = $0 { return text.contains("fell behind") }; return false })
    }

    func testClosedGateCannotBeRearmedOrDeliverOldGenerationCallbacks() async {
        let gate = CaptureDeliveryGate(capacity: 2)
        gate.arm()
        gate.close()
        gate.arm()
        XCTAssertFalse(gate.beginAudioBuffer())
        gate.submit(AudioChunk(role: .you, pcm16: Data(repeating: 0, count: 1600)), level: 0.5)
        var count = 0
        for await _ in gate.stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testResamplesStereo48kToMono16kIn50msChunks() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let encoder = try PCM16ChunkEncoder(format: format, role: .interviewer)
        var chunks: [AudioChunk] = []
        for _ in 0..<20 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for channel in 0..<2 { for frame in 0..<480 { buffer.floatChannelData![channel][frame] = 0.25 } }
            chunks += try encoder.append(buffer)
        }
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.pcm16.count == 1600 && $0.role == .interviewer })
        let samples = chunks.last!.pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(Double(samples[400]) / Double(Int16.max), 0.25, accuracy: 0.02)
    }

    func testEncoderBoundsRemainderAndClipsFloatSamples() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let encoder = try PCM16ChunkEncoder(format: format, role: .you)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = i % 2 == 0 ? 2 : -2 }
        let chunks = try encoder.append(buffer)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.pcm16.count == 1600 })
        let values = chunks[0].pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(values[0], Int16.max)
        XCTAssertEqual(values[1], -Int16.max)
        XCTAssertLessThan(encoder.pendingByteCount, 1600)
    }

    func testNonfiniteSamplesBecomeSilence() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let encoder = try PCM16ChunkEncoder(format: format, role: .you)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        for i in 0..<800 { buffer.floatChannelData![0][i] = .nan }
        let chunks = try encoder.append(buffer)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].pcm16, Data(repeating: 0, count: 1600))
    }
}
