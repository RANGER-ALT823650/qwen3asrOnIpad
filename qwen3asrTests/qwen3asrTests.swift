//
//  qwen3asrTests.swift
//  qwen3asrTests
//
//  Created by 马逸凡 on 2026/7/31.
//

import Testing
@testable import QwenKeyboardHost

struct qwen3asrTests {

    @Test func keyboardRecordingLimitIs32Seconds() {
        #expect(AppGroupBridge.maximumRecordingDuration == 32)
    }

    @Test func transcriptionDeadlineIs180Seconds() {
        #expect(AppGroupBridge.maximumTranscriptionDuration == 180)
    }

    @Test func repeatedShortPhraseProducesWarning() {
        let text = "今天天气很好很好很好很好"
        #expect(TranscriptionQuality.containsSuspiciousRepetition(text))
        #expect(TranscriptionQuality.repetitionWarning(for: text) != nil)
    }

    @Test func repeatedLongSentenceProducesWarning() {
        let text = "请明天上午给我打电话请明天上午给我打电话"
        #expect(TranscriptionQuality.containsSuspiciousRepetition(text))
    }

    @Test func ordinaryTranscriptionDoesNotProduceWarning() {
        let text = "今天天气很好，我们下午一起去公园散步。"
        #expect(!TranscriptionQuality.containsSuspiciousRepetition(text))
        #expect(TranscriptionQuality.repetitionWarning(for: text) == nil)
    }

}
