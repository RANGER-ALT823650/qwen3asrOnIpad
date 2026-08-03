import Foundation

/// Cross-process notification bridge between the container app and the
/// keyboard extension, delivered through the Darwin notification center.
public enum DarwinNotifications {
    /// Posted by the app whenever the shared record status changes.
    public static let statusChanged = "com.project.qwen3asr.statusChanged" as CFString
    /// Posted by the keyboard to ask the (possibly backgrounded) app to start recording.
    public static let startRecording = "com.project.qwen3asr.startRecording" as CFString
    /// Posted by the keyboard to ask the app to stop recording and publish the WAV.
    public static let stopRecording = "com.project.qwen3asr.stopRecording" as CFString
    /// Posted by the keyboard to ask the app to stop and discard the recording.
    public static let cancelRecording = "com.project.qwen3asr.cancelRecording" as CFString

    private static var handlers: [String: () -> Void] = [:]

    public static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }

    public static func observe(_ name: CFString, _ handler: @escaping () -> Void) {
        let key = name as String
        handlers[key] = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(ObserverBox.shared).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, notificationName, _, _ in
                guard let name = notificationName?.rawValue as String? else { return }
                DispatchQueue.main.async {
                    DarwinNotifications.handlers[name]?()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }
}

private final class ObserverBox {
    static let shared = ObserverBox()
}
