import Foundation
import AVFoundation
import Combine

public class AudioRecorder: NSObject, ObservableObject {
    public static let shared = AudioRecorder()

    private let persistentInputEngine = AVAudioEngine()
    private var persistentInputTapInstalled = false
    private var shouldMaintainPersistentInput = false
    private let captureLock = NSLock()
    private var captureFile: AVAudioFile?
    private var captureFileURL: URL?
    private var captureFormat: AVAudioFormat?
    private var captureWriteError: String?

    @Published public var isRecording = false
    @Published public var audioPower: Float = 0.0
    /// True while the app owns an active input audio unit but discards frames.
    /// This keeps the input graph warm between split-screen dictation rounds
    /// without writing ambient audio to disk.
    @Published public private(set) var isMicrophoneWarm = false
    /// Last concrete failure reason, so the UI can show something actionable.
    @Published public private(set) var lastError: String?

    public var isPersistentInputRunning: Bool {
        persistentInputEngine.isRunning
    }

    public override init() {
        super.init()
    }

    /// Writes recordings into the shared App Group container so the keyboard
    /// extension can read the WAV afterwards. Falls back to the temp dir if the
    /// group is unavailable (e.g. missing entitlements during development).
    private static func recordingDirectory() -> URL {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupBridge.groupID) {
            let dir = container.appendingPathComponent("recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default.temporaryDirectory
    }

    /// Removes stale WAVs so the shared container does not grow forever.
    private static func cleanUpOldRecordings(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for file in files where ["wav", "caf"].contains(file.pathExtension.lowercased()) {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Starts the long-lived input unit used between dictation rounds.
    ///
    /// The tap intentionally discards every buffer. A real WAV file is opened
    /// only after the keyboard explicitly requests a recording round.
    @discardableResult
    public func startPersistentInput() -> Bool {
        shouldMaintainPersistentInput = true

        guard !isRecording else { return true }
        if persistentInputEngine.isRunning {
            isMicrophoneWarm = true
            lastError = nil
            return true
        }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            lastError = "麦克风权限未生效，请在 iPad 设置中允许千问3 ASR访问麦克风后重试"
            return false
        }

        do {
            try activateAudioSession()
            try startPersistentInputEngine()
            lastError = nil
            return true
        } catch {
            lastError = "常驻麦克风保持失败: \(error.localizedDescription)"
            print("Failed to keep microphone input active: \(error)")
            return false
        }
    }

    /// Re-establishes the input unit after a phone call, Siri, or an audio
    /// route interruption. It is a no-op until persistent input was requested.
    public func resumePersistentInputIfNeeded() {
        guard shouldMaintainPersistentInput, !isRecording else { return }
        _ = startPersistentInput()
    }

    public func startRecording() -> URL? {
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            lastError = "麦克风权限未生效，请在 iPad 设置中允许千问3 ASR访问麦克风后重试"
            return nil
        }
        guard persistentInputEngine.isRunning, let captureFormat else {
            lastError = "常驻麦克风服务已停止，请保持千问3 ASR在分屏前台后重试"
            return nil
        }

        let dir = Self.recordingDirectory()
        Self.cleanUpOldRecordings(in: dir)
        let fileURL = dir.appendingPathComponent("input_\(UUID().uuidString).caf")

        do {
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: captureFormat.settings,
                commonFormat: captureFormat.commonFormat,
                interleaved: captureFormat.isInterleaved
            )

            captureLock.lock()
            captureFile = file
            captureFileURL = fileURL
            captureWriteError = nil
            captureLock.unlock()

            lastError = nil
            isRecording = true
            isMicrophoneWarm = false
            return fileURL
        } catch {
            lastError = "录音文件创建失败: \(error.localizedDescription)"
            print("Failed to create recording file: \(error)")
        }
        return nil
    }

    public func stopRecording(completion: @escaping (URL?) -> Void) {
        captureLock.lock()
        let recordedURL = captureFileURL
        let writeError = captureWriteError
        captureFile = nil
        captureFileURL = nil
        captureWriteError = nil
        captureLock.unlock()

        isRecording = false
        audioPower = 0
        isMicrophoneWarm = persistentInputEngine.isRunning

        if let writeError {
            lastError = "录音写入失败: \(writeError)"
            if let recordedURL {
                try? FileManager.default.removeItem(at: recordedURL)
            }
            completion(nil)
            return
        }

        completion(recordedURL)
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        try session.setActive(true)
    }

    private func startPersistentInputEngine() throws {
        guard !persistentInputEngine.isRunning else {
            isMicrophoneWarm = true
            return
        }

        let input = persistentInputEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInputFormat
        }

        captureFormat = format
        if !persistentInputTapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }

                self.captureLock.lock()
                if let file = self.captureFile {
                    do {
                        try file.write(from: buffer)
                    } catch {
                        self.captureWriteError = error.localizedDescription
                        self.captureFile = nil
                    }
                }
                self.captureLock.unlock()
            }
            persistentInputTapInstalled = true
        }
        persistentInputEngine.prepare()

        do {
            try persistentInputEngine.start()
            isMicrophoneWarm = true
        } catch {
            isMicrophoneWarm = false
            throw error
        }
    }
}

private enum AudioRecorderError: LocalizedError {
    case noInputFormat

    var errorDescription: String? {
        switch self {
        case .noInputFormat:
            return "系统没有提供可用的麦克风输入格式"
        }
    }
}
