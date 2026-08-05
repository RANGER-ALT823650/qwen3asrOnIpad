import Foundation

@main
enum NineKeyLexiconSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let lexicon = NineKeyLexicon(
                url: URL(fileURLWithPath: CommandLine.arguments[1])
              ) else {
            fatalError("Unable to open lexicon")
        }

        let checks = [
            "64": "你",
            "64426": "你好",
            "94664486": "中国",
        ]
        for (digits, expected) in checks {
            let candidates = lexicon.candidates(for: digits, limit: 20)
            let words = candidates.map(\.text)
            print("\(digits): \(words.prefix(8).joined(separator: ", "))")
            precondition(words.contains(expected), "missing \(expected) for \(digits)")
        }
    }
}
