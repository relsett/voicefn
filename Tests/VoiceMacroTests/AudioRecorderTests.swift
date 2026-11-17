import AVFoundation
import XCTest
@testable import VoiceMacro

final class AudioRecorderTests: XCTestCase {
    func testMeterHandlesSilenceAndClipsFullScale() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<128 { samples[i] = 0 }
        XCTAssertEqual(PCMRecording.normalizedLevel(buffer), 0)
        for i in 0..<128 { samples[i] = 0.1 }
        XCTAssertEqual(PCMRecording.normalizedLevel(buffer), 2.0 / 3.0, accuracy: 0.001)
        for i in 0..<128 { samples[i] = 2 }
        XCTAssertEqual(PCMRecording.normalizedLevel(buffer), 1)
    }

    func testQueuedBufferCopyDoesNotAliasCaptureMemory() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        source.frameLength = 64
        let samples = try XCTUnwrap(source.floatChannelData)
        for channel in 0..<2 { for frame in 0..<64 { samples[channel][frame] = Float(channel + 1) / 4 } }
        let copy = try XCTUnwrap(PCMRecording.copy(source))
        samples[0][0] = 0
        XCTAssertEqual(copy.frameLength, 64)
        XCTAssertEqual(copy.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(copy.floatChannelData?[1][63], 0.5)
    }

    func testStereo48kRecordingIsEncodedLiveAsMono16kFLAC() throws {
        let url = temporaryFLAC()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url) { _ in }
        try enqueueSine(into: writer, sampleRate: 48_000, channels: 2, seconds: 0.5)
        try writer.finish()

        let flac = try Data(contentsOf: url)
        XCTAssertEqual(String(data: flac[0..<4], encoding: .ascii), "fLaC")
        XCTAssertEqual(OpenRouterTranscriptionClient.audioFormat(of: flac), "flac")
        let result = try AVAudioFile(forReading: url)
        XCTAssertEqual(result.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatFLAC)
        XCTAssertEqual(result.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(result.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(result.length) / 16_000, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(PCMRecording.normalizedLevel(try read(result)), 0.5, "Encoding must preserve audible content")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInputFormatChangeMidRecordingContinuesInTheSameFile() throws {
        let url = temporaryFLAC()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url) { _ in }
        try enqueueSine(into: writer, sampleRate: 48_000, channels: 2, seconds: 0.25)
        // A Bluetooth headset switching profiles reconfigures the input to a different format.
        try enqueueSine(into: writer, sampleRate: 24_000, channels: 1, seconds: 0.25)
        try writer.finish()
        let result = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(result.length) / 16_000, 0.5, accuracy: 0.01)
    }

    func testEmptyRecordingIsRejected() throws {
        let url = temporaryFLAC()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url) { _ in }
        XCTAssertThrowsError(try writer.finish())
    }

    private func temporaryFLAC() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
    }

    private func enqueueSine(into writer: RecordingWriter, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let total = Int(sampleRate * seconds)
        let chunk = 2_048
        for offset in stride(from: 0, to: total, by: chunk) {
            let frames = min(chunk, total - offset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<frames {
                let value = Float(sin(2 * .pi * 440 * Double(offset + frame) / sampleRate) * 0.5)
                for channel in 0..<Int(channels) { samples[channel][frame] = value }
            }
            writer.enqueue(buffer)
        }
    }

    private func read(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return buffer
    }

    func testVoicedSecondsTellsAWordFromAClick() throws {
        func buffer(_ samples: (Int) -> Float) throws -> AVAudioPCMBuffer {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = samples(i) }
            return buffer
        }
        let hiss = { (i: Int) -> Float in Float(i % 7 - 3) * 0.0003 }   // about -70 dBFS
        let tone = { (i: Int) -> Float in 0.1 * sin(Float(i) * 2 * .pi * 220 / 48_000) }
        XCTAssertEqual(PCMRecording.voicedSeconds(try buffer(hiss)), 0)
        // A 15 ms key click in a second of quiet: one window, two if it straddles them.
        let click = PCMRecording.voicedSeconds(try buffer { (10_000..<10_720).contains($0) ? 0.5 : hiss($0) })
        XCTAssertLessThan(click, SpeechGate.standard.minimumVoicedSeconds)
        // A quick 250 ms word.
        let word = PCMRecording.voicedSeconds(try buffer { (20_000..<32_000).contains($0) ? tone($0) : hiss($0) })
        XCTAssertEqual(word, 0.25, accuracy: 0.04)  // edge windows count whole
        XCTAssertNil(SpeechGate.standard.reject(voicedSeconds: word))
    }
}
