import Foundation
import Combine

@MainActor
final class NineKeyInputModel: ObservableObject {
    @Published private(set) var digits = ""
    @Published private(set) var candidates: [NineKeyCandidate] = []

    private let lexicon: NineKeyLexicon?
    private let history = NineKeyBigramHistory()
    private var context = ""

    init(lexicon: NineKeyLexicon? = NineKeyLexicon()) {
        self.lexicon = lexicon
    }

    var isComposing: Bool { !digits.isEmpty }

    func append(_ digit: Character, contextBeforeInput: String?) {
        guard ("2"..."9").contains(String(digit)), digits.count < 32 else { return }
        digits.append(digit)
        context = Self.trailingContext(from: contextBeforeInput)
        refreshCandidates()
    }

    func deleteBackward() {
        guard !digits.isEmpty else { return }
        digits.removeLast()
        refreshCandidates()
    }

    func cancelComposition() {
        digits = ""
        candidates = []
        context = ""
    }

    func commit(_ candidate: NineKeyCandidate) -> String {
        history.learn(context: context, candidate: candidate.text)
        let text = candidate.text
        cancelComposition()
        return text
    }

    func commitFirstCandidate() -> String? {
        guard let first = candidates.first else { return nil }
        return commit(first)
    }

    private func refreshCandidates() {
        guard !digits.isEmpty else {
            candidates = []
            return
        }

        candidates = (lexicon?.candidates(for: digits) ?? [])
            .map { candidate in
                NineKeyCandidate(
                    text: candidate.text,
                    baseFrequency: candidate.baseFrequency,
                    score: candidate.score + history.boost(
                        context: context,
                        candidate: candidate.text
                    )
                )
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.text < $1.text
            }
    }

    private static func trailingContext(from text: String?) -> String {
        guard let text else { return "" }
        let meaningful = text.reversed().prefix { !$0.isWhitespace && !$0.isNewline }
        return String(meaningful.prefix(2).reversed())
    }
}

/// A bounded, device-local bigram table. It learns only explicit candidate
/// selections and never retains document text beyond the final two characters.
private final class NineKeyBigramHistory {
    private let defaults = UserDefaults(suiteName: AppGroupBridge.suiteName)
    private let storageKey = "nineKeyBigramHistory.v1"
    private let maximumPairs = 512
    private var counts: [String: Int]

    init() {
        counts = defaults?.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }

    func boost(context: String, candidate: String) -> Int {
        guard !context.isEmpty else { return 0 }
        let count = counts[key(context: context, candidate: candidate)] ?? 0
        return count == 0 ? 0 : Int(log2(Double(count + 1)) * 1_200)
    }

    func learn(context: String, candidate: String) {
        guard !context.isEmpty else { return }
        let pair = key(context: context, candidate: candidate)
        counts[pair, default: 0] = min(255, counts[pair, default: 0] + 1)

        if counts.count > maximumPairs,
           let leastUsed = counts.min(by: { $0.value < $1.value })?.key {
            counts.removeValue(forKey: leastUsed)
        }
        defaults?.set(counts, forKey: storageKey)
    }

    private func key(context: String, candidate: String) -> String {
        "\(context)\u{1F}\(candidate)"
    }
}
