import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum AudioRecordingError: LocalizedError {
    case permissionDenied, alreadyRecording, noRecording, unavailableDevice, invalidFormat, writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return String(localized: "Allow microphone access in System Settings.")
        case .alreadyRecording: return String(localized: "Already recording.")
        case .noRecording: return String(localized: "Nothing to transcribe.")
        case .unavailableDevice: return String(localized: "The selected microphone isn’t available.")
        case .invalidFormat: return String(localized: "The microphone uses an unsupported audio format.")
        case .writeFailed(let reason): return String(localized: "Couldn’t save the recording: \(reason)")
        }
    }
}

/// Microphone ownership stays on the main actor; samples are encoded on a serial worker.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var level: Double = 0
    /// How long the last stopped recording was louder than silence, to tell speech from a tap.
    private(set) var voicedSeconds: Double?
    @Published private(set) var isRecording = false
    var onInterruption: ((String) -> Void)?
    var hasRecording: Bool { writer != nil }

    private var engine: AVAudioEngine?
    private var writer: RecordingWriter?
    private var deviceUID: String?
    private var configurationObserver: NSObjectProtocol?
    private var configurationRestarts = 0
    private var tapInstalled = false
    private var sessionID = UUID()
    private var pendingStartID: UUID?

    nonisolated static func availableDevices() -> [AudioInputDevice] {
        CoreAudioInputs.devices().map { AudioInputDevice(id: $0.uid, name: $0.name) }
    }

    func start(deviceUID: String? = nil) async throws {
        guard writer == nil, pendingStartID == nil else { throw AudioRecordingError.alreadyRecording }
        try Task.checkCancellation()
        let id = UUID()
        pendingStartID = id
        sessionID = id
        defer { if pendingStartID == id { pendingStartID = nil } }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard pendingStartID == id, sessionID == id else { throw CancellationError() }
        guard granted else { throw AudioRecordingError.permissionDenied }
        // Permission may have suspended this task while another start was requested.
        guard writer == nil else { throw AudioRecordingError.alreadyRecording }
        let directory = try Self.recordingsDirectory()
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
        let writer = try RecordingWriter(url: url) { [weak self] level in
            Task { @MainActor in
                guard let self, self.sessionID == id, self.isRecording else { return }
                self.level = level
            }
        }
        let engine = AVAudioEngine()
        self.engine = engine
        self.writer = writer
        voicedSeconds = nil
        self.deviceUID = deviceUID?.isEmpty == false ? deviceUID : nil
        configurationRestarts = 0
        do {
            try startEngine()
            isRecording = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == id, self.isRecording else { return }
                    self.recoverFromConfigurationChange()
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let writer else { throw AudioRecordingError.noRecording }
        releaseMicrophone()
        self.writer = nil
        sessionID = UUID()
        // Audio is resampled and encoded while recording, so only the file tail remains.
        let url = try await Task.detached(priority: .userInitiated) {
            do {
                try writer.finish()
                return writer.url
            } catch {
                try? FileManager.default.removeItem(at: writer.url)
                throw error
            }
        }.value
        voicedSeconds = writer.voicedSeconds
        return url
    }

    func cancel() {
        releaseMicrophone()
        let writer = self.writer
        self.writer = nil
        pendingStartID = nil
        sessionID = UUID()
        writer?.discard()
    }

    private func startEngine() throws {
        guard let engine, let writer else { throw AudioRecordingError.noRecording }
        let input = engine.inputNode
        if let deviceUID {
            guard var device = CoreAudioInputs.devices().first(where: { $0.uid == deviceUID })?.device,
                  let unit = input.audioUnit else { throw AudioRecordingError.unavailableDevice }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &device,
                                             UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioRecordingError.unavailableDevice }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecordingError.invalidFormat }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            writer.enqueue(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// Route changes (other output device, Bluetooth profile switch) stop the engine.
    /// Keep recording into the same file while the selected microphone is still present;
    /// the writer resamples whatever input format the device now delivers.
    private func recoverFromConfigurationChange() {
        guard let engine else { return }
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        configurationRestarts += 1
        do {
            guard configurationRestarts <= 5 else { throw AudioRecordingError.unavailableDevice }
            try startEngine()
        } catch {
            releaseMicrophone()
            onInterruption?(String(localized: "The microphone changed. The recording is saved."))
        }
    }

    private func releaseMicrophone() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
        deviceUID = nil
        isRecording = false
        level = 0
    }

    nonisolated static func recordingsDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("VoiceMacro/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Startup maintenance only; completed recordings otherwise belong to the caller.
    nonisolated static func removeExpiredRecordings(olderThan age: TimeInterval = 24 * 60 * 60) {
        guard let directory = try? recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files where ["caf", "wav", "flac"].contains(file.pathExtension) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Resamples captured audio to 16 kHz mono and encodes it as 16-bit FLAC while recording:
/// speech recognition needs nothing more, and the upload is several times smaller than WAV.
final class RecordingWriter: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!
    let url: URL
    private let queue = DispatchQueue(label: "VoiceMacro.audio-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var file: ExtAudioFileRef?
    private var converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    private var framesWritten: Int64 = 0
    private var writeError: Error?
    private var lastLevelTime: TimeInterval = 0
    private var voiced: Double = 0
    private let reportLevel: (Double) -> Void

    /// Seconds of input louder than silence so far; complete once `finish()` returns.
    var voicedSeconds: Double { queue.sync { voiced } }

    init(url: URL, reportLevel: @escaping (Double) -> Void) throws {
        self.url = url
        self.reportLevel = reportLevel
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 4_096) else {
            throw AudioRecordingError.invalidFormat
        }
        self.output = output
        // The AVAudioFile settings dictionary cannot express the FLAC source bit depth.
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.outputFormat.sampleRate, mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &description, nil,
                                               AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else { throw AudioRecordingError.writeFailed("FLAC (\(status))") }
        file = created
        status = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                         Self.outputFormat.streamDescription)
        do {
            guard status == noErr else { throw AudioRecordingError.writeFailed("FLAC (\(status))") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            _ = closeFile()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { _ = closeFile() }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard pending < 64 else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        guard let copy = PCMRecording.copy(buffer) else {
            lock.lock(); pending -= 1; lock.unlock()
            return
        }
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            self.write(copy)
            self.voiced += PCMRecording.voicedSeconds(copy)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastLevelTime >= 0.05 {
                self.lastLevelTime = now
                self.reportLevel(PCMRecording.normalizedLevel(copy))
            }
        }
    }

    func finish() throws {
        try queue.sync {
            if writeError == nil {
                do { try drainConverter() } catch { writeError = error }
            }
            let status = closeFile()
            if writeError == nil, status != noErr { writeError = AudioRecordingError.writeFailed("FLAC (\(status))") }
            if let writeError { throw writeError as? AudioRecordingError ?? .writeFailed(writeError.localizedDescription) }
            // Buffers dropped while the Mac was busy leave a short gap; the rest of what the user
            // said is still worth transcribing, so a gap never costs the whole recording.
            guard framesWritten > 0 else { throw AudioRecordingError.noRecording }
        }
    }

    func discard() {
        queue.async {
            _ = self.closeFile()
            try? FileManager.default.removeItem(at: self.url)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard writeError == nil, file != nil else { return }
        do {
            if converter?.inputFormat != buffer.format {
                // A device change can deliver a new input format; flush the old resampler first.
                try drainConverter()
                guard let next = AVAudioConverter(from: buffer.format, to: Self.outputFormat) else {
                    throw AudioRecordingError.invalidFormat
                }
                next.downmix = true
                converter = next
            }
            try convert(buffer)
        } catch { writeError = error }
    }

    private func drainConverter() throws {
        try convert(nil)
        converter = nil
    }

    /// Converts one captured buffer, or flushes the resampler tail when `input` is nil.
    private func convert(_ input: AVAudioPCMBuffer?) throws {
        guard let converter else { return }
        var supplied = false
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let input else { inputStatus.pointee = .endOfStream; return nil }
                guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if status == .error { throw AudioRecordingError.invalidFormat }
            if output.frameLength > 0 { try append(output) }
            guard status == .haveData, output.frameLength > 0 else { return }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else { throw AudioRecordingError.writeFailed("FLAC (\(status))") }
        framesWritten += Int64(buffer.frameLength)
    }

    private func closeFile() -> OSStatus {
        guard let file else { return noErr }
        self.file = nil
        return ExtAudioFileDispose(file)
    }
}

enum PCMRecording {
    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        target.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard sourceBuffers.count == targetBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            guard let from = sourceBuffers[index].mData, let to = targetBuffers[index].mData else { return nil }
            memcpy(to, from, Int(sourceBuffers[index].mDataByteSize))
        }
        return target
    }

    /// Level (0 = -60 dBFS, 1 = 0 dBFS) above which a 20 ms window counts as sound; 0.25 is -45 dBFS.
    static let voiceLevel = 0.25

    /// Total length of the 20 ms windows louder than `voiceLevel`. A key click lasts a window or
    /// two; even a quick word lasts several.
    static func voicedSeconds(_ buffer: AVAudioPCMBuffer, level threshold: Double = voiceLevel) -> Double {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard frames > 0, channels > 0, rate > 0 else { return 0 }
        let window = max(1, Int(rate * 0.02))
        // -60 dBFS + threshold × 60 dB, as a mean square.
        let minimumPower = pow(10, (threshold * 60 - 60) / 10)
        let stride = buffer.format.isInterleaved ? channels : 1
        var voicedFrames = 0
        var start = 0
        while start < frames {
            let end = min(frames, start + window)
            var sum = 0.0
            for channel in 0..<channels {
                let plane = buffer.format.isInterleaved ? 0 : channel
                for frame in start..<end {
                    let index = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                    let sample: Double
                    switch buffer.format.commonFormat {
                    case .pcmFormatFloat32: sample = Double(buffer.floatChannelData?[plane][index] ?? 0)
                    case .pcmFormatInt16: sample = Double(buffer.int16ChannelData?[plane][index] ?? 0) / 32768
                    case .pcmFormatInt32: sample = Double(buffer.int32ChannelData?[plane][index] ?? 0) / 2147483648
                    default: return 0
                    }
                    if sample.isFinite { sum += sample * sample }
                }
            }
            if sum / Double((end - start) * channels) >= minimumPower { voicedFrames += end - start }
            start = end
        }
        return Double(voicedFrames) / rate
    }

    static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else { return 0 }
        var sum = 0.0
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        guard channels > 0 else { return 0 }
        for channel in 0..<channels {
            for frame in 0..<frames {
                let index = frame * stride + (buffer.format.isInterleaved ? channel : 0)
                let plane = buffer.format.isInterleaved ? 0 : channel
                let sample: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32: sample = Double(buffer.floatChannelData?[plane][index] ?? 0)
                case .pcmFormatInt16: sample = Double(buffer.int16ChannelData?[plane][index] ?? 0) / 32768
                case .pcmFormatInt32: sample = Double(buffer.int32ChannelData?[plane][index] ?? 0) / 2147483648
                default: return 0
                }
                if sample.isFinite { sum += sample * sample }
            }
        }
        let rms = sqrt(sum / Double(frames * channels))
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
}

private enum CoreAudioInputs {
    struct Device { let device: AudioDeviceID; let uid: String; let name: String }

    static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, id: id),
                  let name = stringProperty(kAudioObjectPropertyName, id: id) else { return nil }
            return Device(device: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
