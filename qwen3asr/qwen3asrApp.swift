//
//  qwen3asrApp.swift
//  qwen3asr
//
//  Created by 马逸凡 on 2026/7/31.
//

import SwiftUI
import AVFoundation

@main
struct qwen3asrApp: App {
    @UIApplicationDelegateAdaptor(Qwen3ASRAppDelegate.self) private var appDelegate
    @StateObject private var recordController = AppRecordController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordController)
                .onOpenURL { url in
                    recordController.handle(url: url)
                }
                .task {
                    StartupPermissionCoordinator.shared.requestOnLaunch { granted in
                        recordController.preparePersistentRuntime(permissionGranted: granted)
                    }
                }
        }
    }
}

/// Requests microphone access during the first foreground launch.
@MainActor
final class StartupPermissionCoordinator {
    static let shared = StartupPermissionCoordinator()

    private var didStart = false

    private init() {}

    func requestOnLaunch(microphoneCompletion: @escaping (Bool) -> Void) {
        guard !didStart else { return }
        didStart = true

        requestMicrophonePermission { granted in
            microphoneCompletion(granted)
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let permission = AVAudioSession.sharedInstance().recordPermission
        guard permission == .undetermined else {
            completion(permission == .granted)
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

}

/// Handles the non-scene URL callback when UIKit supplies one. SwiftUI's
/// `.onOpenURL` remains the primary scene path, while AppRecordController also
/// consumes the App Group request if a cold launch loses the URL payload.
final class Qwen3ASRAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppRecordController.shared.handle(url: url)
        return true
    }
}
