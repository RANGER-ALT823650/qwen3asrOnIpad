import Foundation

/// Shared state channel between the qwen3asr container app and the
/// Qwen3ASRKeyboard extension, backed by the App Group container.
public enum AppGroupBridge {
    public static let groupID = "group.project.qwen3asr"
    public static let suiteName = groupID

    public enum Keys {
        public static let status = "recordStatus"
        public static let wavPath = "pendingWavPath"
        public static let message = "statusMessage"
        public static let updatedAt = "statusUpdatedAt"
    }

    public enum RecordStatus: String {
        case idle = "idle"
        case requested = "requested"   // keyboard asked the app to start
        case recording = "recording"   // app holds the mic
        case stopped = "stopped"       // app finished, WAV path is published
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
        if status == .idle {
            // An idle status must never leave a stale pending WAV behind.
            defaults.removeObject(forKey: Keys.wavPath)
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

    public static var lastMessage: String? {
        defaults?.string(forKey: Keys.message)
    }

    public static var updatedAt: TimeInterval {
        defaults?.double(forKey: Keys.updatedAt) ?? 0
    }

    public static func clearPending() {
        defaults?.removeObject(forKey: Keys.wavPath)
        defaults?.removeObject(forKey: Keys.message)
    }
}
