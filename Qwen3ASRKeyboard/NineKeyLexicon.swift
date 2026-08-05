import Foundation

struct NineKeyCandidate: Identifiable, Equatable {
    let text: String
    let baseFrequency: Int
    let score: Int

    var id: String { text }
}

/// Read-only, memory-mapped lexicon for the nine-key keyboard.
///
/// The build artifact stores only the T9 digit sequence, word and frequency.
/// Pinyin is used by the build tool to produce the digit sequence, but is not
/// duplicated in the runtime file. A small offset table enables binary search
/// without decoding the complete lexicon into Swift strings.
final class NineKeyLexicon {
    private static let magic = Array("Q9LX".utf8)
    private static let headerSize = 12

    private let data: Data
    private let entryCount: Int
    private var cache: [String: [NineKeyCandidate]] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity = 32

    convenience init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "pinyin9", withExtension: "lex") else {
            return nil
        }
        self.init(url: url)
    }

    init?(url: URL) {
        guard let mappedData = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              mappedData.count >= Self.headerSize,
              Array(mappedData.prefix(4)) == Self.magic else {
            return nil
        }

        let version = Self.readUInt16(from: mappedData, at: 4)
        let count = Int(Self.readUInt32(from: mappedData, at: 8))
        let offsetsEnd = Self.headerSize + (count + 1) * MemoryLayout<UInt32>.size
        guard version == 1, count > 0, offsetsEnd <= mappedData.count else {
            return nil
        }

        data = mappedData
        entryCount = count
    }

    func candidates(for digits: String, limit: Int = 12) -> [NineKeyCandidate] {
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({ (0x32...0x39).contains($0) }) else {
            return []
        }

        let cacheKey = "\(digits)#\(limit)"
        if let cached = cache[cacheKey] {
            touch(cacheKey)
            return cached
        }

        let lower = lowerBound(for: Array(digits.utf8))
        let upper = lowerBound(for: Array("\(digits):".utf8))
        guard lower < upper else {
            store([], for: cacheKey)
            return []
        }

        var bestByWord: [String: NineKeyCandidate] = [:]
        bestByWord.reserveCapacity(limit * 2)

        for index in lower..<upper {
            guard let record = record(at: index) else { continue }
            let isExact = record.codeLength == digits.utf8.count
            let lengthPenalty = max(0, record.codeLength - digits.utf8.count) * 30
            // A complete digit-code match must outrank a high-frequency word
            // that merely shares the prefix (for example, 64: 你 vs 年/面积).
            let score = record.frequency + (isExact ? 1_000_000_000 : 0) - lengthPenalty
            let candidate = NineKeyCandidate(
                text: record.word,
                baseFrequency: record.frequency,
                score: score
            )
            if candidate.score > (bestByWord[candidate.text]?.score ?? .min) {
                bestByWord[candidate.text] = candidate
            }
        }

        let result = bestByWord.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.text.count != $1.text.count { return $0.text.count < $1.text.count }
                return $0.text < $1.text
            }
            .prefix(limit)
            .map { $0 }

        store(result, for: cacheKey)
        return result
    }

    private struct Record {
        let codeLength: Int
        let word: String
        let frequency: Int
    }

    private func record(at index: Int) -> Record? {
        let start = recordOffset(at: index)
        let end = recordOffset(at: index + 1)
        guard start + 6 <= end, end <= data.count else { return nil }

        let codeLength = Int(data[start])
        let wordLength = Int(data[start + 1])
        let wordStart = start + 6 + codeLength
        let wordEnd = wordStart + wordLength
        guard wordEnd <= end else { return nil }

        return Record(
            codeLength: codeLength,
            word: String(decoding: data[wordStart..<wordEnd], as: UTF8.self),
            frequency: Int(Self.readUInt32(from: data, at: start + 2))
        )
    }

    private func lowerBound(for key: [UInt8]) -> Int {
        var low = 0
        var high = entryCount
        while low < high {
            let middle = (low + high) / 2
            if compareCode(at: middle, with: key) < 0 {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func compareCode(at index: Int, with key: [UInt8]) -> Int {
        let start = recordOffset(at: index)
        guard start < data.count else { return 1 }
        let codeLength = Int(data[start])
        let codeStart = start + 6
        let sharedCount = min(codeLength, key.count)

        for offset in 0..<sharedCount {
            let lhs = data[codeStart + offset]
            let rhs = key[offset]
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        if codeLength == key.count { return 0 }
        return codeLength < key.count ? -1 : 1
    }

    private func recordOffset(at index: Int) -> Int {
        let offsetPosition = Self.headerSize + index * MemoryLayout<UInt32>.size
        return Int(Self.readUInt32(from: data, at: offsetPosition))
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func store(_ candidates: [NineKeyCandidate], for key: String) {
        cache[key] = candidates
        touch(key)
        if cacheOrder.count > cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
