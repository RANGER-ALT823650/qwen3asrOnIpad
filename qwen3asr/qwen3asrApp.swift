//
//  qwen3asrApp.swift
//  qwen3asr
//
//  Created by 马逸凡 on 2026/7/31.
//

import SwiftUI

@main
struct qwen3asrApp: App {
    @StateObject private var recordController = AppRecordController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordController)
                .onOpenURL { url in
                    recordController.handle(url: url)
                }
        }
    }
}
