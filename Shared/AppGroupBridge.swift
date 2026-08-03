import Foundation

/// Shared state channel between the qwen3asr container app and the
/// Qwen3ASRKeyboard extension, backed by the App Group container.
public enum AppGroupBridge {
    public static let groupID = "group.project.qwen3asr"
    public static let suiteName = groupID

    public enum Keys {
        public static let status = "recordStatus"
        public static let wavPath = "pendingWavPath"
        public static let transcriptionText = "transcriptionText"
        public static let message = "statusMessage"
        public static let updatedAt = "statusUpdatedAt"
        public static let keyboardActiveAt = "keyboardActiveAt"
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

    public static func setStatus(_ status: RecordStatus, message: String? = nil, wavPath: String? = nil) {
        guard let defaults else { return }
        defaults.set(status.rawValue, forKey: Keys.status)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        if let message {
            defaults.set(message, forKey: Keys.message)
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
        if status == .requested, message == nil {
            defaults.removeObject(forKey: Keys.message)
        }
        defaults.synchronize()
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

    public static func setTranscription(_ text: String) {
        guard let defaults else { return }
        defaults.set(text, forKey: Keys.transcriptionText)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.updatedAt)
        defaults.synchronize()
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
    }
}
