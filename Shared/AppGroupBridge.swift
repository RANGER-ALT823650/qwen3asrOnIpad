import Foundation

/// Shared state channel between the qwen3asr container app and the
/// Qwen3ASRKeyboard extension, backed by the App Group container.
public enum AppGroupBridge {
    public static let groupID = "group.project.qwen3asr"
    public static let suiteName = groupID
    public static let maximumRecordingDuration: TimeInterval = 32
    public static let maximumTranscriptionDuration: TimeInterval = 180

    public enum Keys {
        public static let status = "recordStatus"
        public static let wavPath = "pendingWavPath"
        public static let transcriptionText = "transcriptionText"
        public static let message = "statusMessage"
        public static let updatedAt = "statusUpdatedAt"
        public static let keyboardActiveAt = "keyboardActiveAt"
        public static let requestID = "recordRequestID"
        public static let acknowledgedRequestID = "acknowledgedRecordRequestID"
        public static let transcriptionLaunchID = "transcriptionLaunchID"
        public static let transcriptionStartedAt = "transcriptionStartedAt"
    }

    public enum RecordStatus: String {
        case idle = "idle"
        case requested = "requested"   // keyboard asked the app to start
        case recording = "recording"   // app holds the mic
        case stopped = "stopped"       // legacy: app finished, WAV path is published
        case transcribing = "transcribing" // host app is using its resident model
        case completed = "completed"   // host app published transcriptionText
        case micDenied = "micDenied"   // microphone permission refused
        case error = "error"
    }

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Starts a completely new keyboard round. The UUID travels with the WAV
    /// and final text so a late result can never complete a newer request.
    @discardableResult
    public static func beginRequest() -> String {
        let requestID = UUID().uuidString
        guard let defaults else { return requestID }

        if let stalePath = defaults.string(forKey: Keys.wavPath) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stalePath))
        }
        defaults.set(requestID, forKey: Keys.requestID)
        defaults.set(RecordStatus.requested.rawValue, forKey: Keys.status)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        defaults.removeObject(forKey: Keys.acknowledgedRequestID)
        defaults.removeObject(forKey: Keys.wavPath)
        defaults.removeObject(forKey: Keys.transcriptionText)
        defaults.removeObject(forKey: Keys.message)
        defaults.removeObject(forKey: Keys.transcriptionLaunchID)
        defaults.removeObject(forKey: Keys.transcriptionStartedAt)
        defaults.synchronize()
        return requestID
    }

    /// Confirms that the resident container process received this exact round.
    /// Recording setup may take longer than the keyboard's fallback delay, so
    /// acknowledgement is tracked separately from the `.recording` status.
    @discardableResult
    public static func acknowledgeRecordingRequest(_ requestID: String) -> Bool {
        guard let defaults,
              defaults.string(forKey: Keys.requestID) == requestID,
              defaults.string(forKey: Keys.status) == RecordStatus.requested.rawValue else {
            return false
        }
        defaults.set(requestID, forKey: Keys.acknowledgedRequestID)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        defaults.set("模型 App 已响应，正在启动录音…", forKey: Keys.message)
        defaults.synchronize()
        return true
    }

    public static func hasAcknowledgedRecordingRequest(_ requestID: String) -> Bool {
        defaults?.string(forKey: Keys.acknowledgedRequestID) == requestID
    }

    public static func setStatus(_ status: RecordStatus, message: String? = nil, wavPath: String? = nil) {
        guard let defaults else { return }
        defaults.set(status.rawValue, forKey: Keys.status)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        if let message {
            defaults.set(message, forKey: Keys.message)
        } else if status == .idle || status == .requested || status == .completed {
            defaults.removeObject(forKey: Keys.message)
        }
        if let wavPath {
            defaults.set(wavPath, forKey: Keys.wavPath)
        }
        if status == .idle || status == .requested {
            // A new round must never inherit the previous round's audio or
            // transcription. This also makes a cold-launch request fully
            // self-contained when the URL hand-off arrives late.
            defaults.removeObject(forKey: Keys.wavPath)
            defaults.removeObject(forKey: Keys.transcriptionText)
        }
        if status == .idle {
            defaults.removeObject(forKey: Keys.requestID)
            defaults.removeObject(forKey: Keys.acknowledgedRequestID)
            defaults.removeObject(forKey: Keys.transcriptionLaunchID)
            defaults.removeObject(forKey: Keys.transcriptionStartedAt)
        } else if status == .requested {
            defaults.removeObject(forKey: Keys.transcriptionLaunchID)
            defaults.removeObject(forKey: Keys.transcriptionStartedAt)
        }
        defaults.synchronize()
    }

    /// Claims a transcription for this concrete app process. If the process is
    /// later force-quit, the next launch sees a different launch ID and treats
    /// the persisted WAV as interrupted work instead of automatically rerunning it.
    @discardableResult
    public static func markTranscribing(
        requestID: String,
        launchID: String,
        message: String,
        wavPath: String
    ) -> Bool {
        guard let defaults,
              defaults.string(forKey: Keys.requestID) == requestID else {
            return false
        }
        defaults.set(requestID, forKey: Keys.requestID)
        defaults.set(launchID, forKey: Keys.transcriptionLaunchID)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.transcriptionStartedAt)
        defaults.set(RecordStatus.transcribing.rawValue, forKey: Keys.status)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        defaults.set(message, forKey: Keys.message)
        defaults.set(wavPath, forKey: Keys.wavPath)
        defaults.removeObject(forKey: Keys.transcriptionText)
        defaults.synchronize()
        return true
    }

    public static var status: RecordStatus {
        guard let defaults, let raw = defaults.string(forKey: Keys.status) else { return .idle }
        return RecordStatus(rawValue: raw) ?? .idle
    }

    public static var pendingWavPath: String? {
        defaults?.string(forKey: Keys.wavPath)
    }

    public static var transcriptionText: String? {
        defaults?.string(forKey: Keys.transcriptionText)
    }

    @discardableResult
    public static func setTranscription(_ text: String, for requestID: String) -> Bool {
        guard let defaults,
              defaults.string(forKey: Keys.requestID) == requestID else { return false }
        defaults.set(text, forKey: Keys.transcriptionText)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        defaults.synchronize()
        return true
    }

    public static var currentRequestID: String? {
        defaults?.string(forKey: Keys.requestID)
    }

    public static var currentTranscriptionLaunchID: String? {
        defaults?.string(forKey: Keys.transcriptionLaunchID)
    }

    public static var transcriptionStartedAt: TimeInterval {
        defaults?.double(forKey: Keys.transcriptionStartedAt) ?? 0
    }

    public static func ownsTranscription(requestID: String, launchID: String) -> Bool {
        status == .transcribing
            && currentRequestID == requestID
            && currentTranscriptionLaunchID == launchID
    }

    public static var lastMessage: String? {
        defaults?.string(forKey: Keys.message)
    }

    public static var updatedAt: TimeInterval {
        defaults?.double(forKey: Keys.updatedAt) ?? 0
    }

    public static var statusAge: TimeInterval {
        let timestamp = updatedAt
        guard timestamp > 0 else { return .infinity }
        return max(0, Date().timeIntervalSince1970 - timestamp)
    }

    /// Called periodically while this keyboard is the visible input view.
    /// The host uses the heartbeat to stop writing a round if the user closes
    /// the keyboard or switches to another input method.
    public static func markKeyboardActive() {
        guard let defaults else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.keyboardActiveAt)
        defaults.synchronize()
    }

    public static var keyboardActiveAge: TimeInterval {
        let timestamp = defaults?.double(forKey: Keys.keyboardActiveAt) ?? 0
        guard timestamp > 0 else { return .infinity }
        return max(0, Date().timeIntervalSince1970 - timestamp)
    }

    public static func clearPending() {
        defaults?.removeObject(forKey: Keys.wavPath)
        defaults?.removeObject(forKey: Keys.transcriptionText)
        defaults?.removeObject(forKey: Keys.message)
        defaults?.removeObject(forKey: Keys.requestID)
        defaults?.removeObject(forKey: Keys.acknowledgedRequestID)
        defaults?.removeObject(forKey: Keys.transcriptionLaunchID)
        defaults?.removeObject(forKey: Keys.transcriptionStartedAt)
    }
}
