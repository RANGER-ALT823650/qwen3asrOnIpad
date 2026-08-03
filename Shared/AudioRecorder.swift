import Foundation
import AVFoundation
import Combine

public class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    public static let shared = AudioRecorder()

    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?

    @Published public var isRecording = false
    @Published public var audioPower: Float = 0.0
    /// Last concrete failure reason, so the UI can show something actionable.
    @Published public private(set) var lastError: String?
    private var timer: Timer?

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
        for file in files where file.pathExtension == "wav" {
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

    public func startRecording() -> URL? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            lastError = "音频会话启动失败: \(error.localizedDescription)"
            print("Failed to set audio session: \(error)")
            return nil
        }

        let dir = Self.recordingDirectory()
        Self.cleanUpOldRecordings(in: dir)
        let fileURL = dir.appendingPathComponent("input_\(Int(Date().timeIntervalSince1970)).wav")
        self.audioFileURL = fileURL

        // 16kHz, 16-bit PCM, Mono WAV — the format Whisper expects.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true

            if audioRecorder?.record() == true {
                lastError = nil
                isRecording = true
                startPowerTimer()
                return fileURL
            }
            lastError = "录音器启动失败（record() 返回 false），可能是麦克风被占用或权限未生效"
        } catch {
            lastError = "录音器创建失败: \(error.localizedDescription)"
            print("Failed to start recording: \(error)")
        }
        return nil
    }

    public func stopRecording(completion: @escaping (URL?) -> Void) {
        stopPowerTimer()
        audioRecorder?.stop()
        isRecording = false

        let recordedURL = self.audioFileURL
        self.audioFileURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }

        completion(recordedURL)
    }

    private func startPowerTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
            DispatchQueue.main.async {
                self.audioPower = normalized
            }
        }
    }

    private func stopPowerTimer() {
        timer?.invalidate()
        timer = nil
        audioPower = 0.0
    }
}
