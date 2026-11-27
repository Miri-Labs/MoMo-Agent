import Foundation

/// Pure-Swift Qwen3 / Qwen2 byte-level BPE tokenizer compatible with Hugging Face
/// `vocab.json` + `merges.txt` + `tokenizer.json` (added_tokens).
public final class BPEQwenTokenizer: @unchecked Sendable {
    public struct AddedToken {
        public let id: Int32
        public let content: String
        public let singleWord: Bool
        public let special: Bool
    }

    private struct TrieNode {
        var next: [UInt8: Int] = [:]
        var tokenIndex: Int = -1
    }

    private var byteToUnicode: [String] = Array(repeating: "", count: 256)
    private var cpToByte: [Int16] = Array(repeating: -1, count: 512)
    private var token2id: [String: Int32] = [:]
    private var id2token: [String] = []
    private var mergesRank: [String: Int32] = [:]
    private var addedTokens: [AddedToken] = []
    private var trie: [TrieNode] = [TrieNode()]
    private var specialIds: Set<Int32> = []
    private var bpeCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    public private(set) var eosTokenId: Int32 = 151645
    public private(set) var imEndTokenId: Int32 = 151645
    public private(set) var padTokenId: Int32 = 151643
    public private(set) var audioTokenId: Int32 = 151671

    public init(directory: URL) throws {
        buildBytesToUnicode()

        let vocabData = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        guard let vocabDict = try JSONSerialization.jsonObject(with: vocabData) as? [String: NSNumber] else {
            throw SpeechEngineError.invalidBundle("Malformed vocab.json")
        }
        token2id.reserveCapacity(vocabDict.count + 64)
        for (k, v) in vocabDict {
            token2id[k] = v.int32Value
        }

        let mergesText = try String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8)
        parseMerges(mergesText)

        let tokenizerJsonURL = directory.appendingPathComponent("tokenizer.json")
        if FileManager.default.fileExists(atPath: tokenizerJsonURL.path) {
            for item in Self.readAddedTokens(from: tokenizerJsonURL) {
                guard let idNum = item["id"] as? NSNumber,
                      let content = item["content"] as? String,
                      !content.isEmpty else { continue }
                let sw = (item["single_word"] as? Bool) ?? false
                let sp = (item["special"] as? Bool) ?? false
                let tok = AddedToken(id: idNum.int32Value, content: content, singleWord: sw, special: sp)
                addedTokens.append(tok)
                token2id[content] = tok.id
                if sp {
                    specialIds.insert(tok.id)
                }
            }
        }

        var maxId: Int32 = -1
        for (_, v) in token2id {
            if v > maxId { maxId = v }
        }
        guard maxId >= 0 else {
            throw SpeechEngineError.invalidBundle("Empty Qwen3 vocabulary")
        }
        let addedSet = Set(addedTokens.map(\.content))
        id2token = Array(repeating: "", count: Int(maxId) + 1)
        for (k, v) in token2id where v >= 0 {
            let idx = Int(v)
            if id2token[idx].isEmpty || (!addedSet.contains(id2token[idx]) && addedSet.contains(k)) {
                id2token[idx] = k
            }
        }

        // Build UTF-8 byte trie for added_tokens matching
        for (idx, tok) in addedTokens.enumerated() {
            var node = 0
            for b in tok.content.utf8 {
                if let nxt = trie[node].next[b] {
                    node = nxt
                } else {
                    let nxt = trie.count
                    trie.append(TrieNode())
                    trie[node].next[b] = nxt
                    node = nxt
                }
            }
            trie[node].tokenIndex = idx
        }

        let resolvedImEnd = token2id["<|im_end|>"] ?? 151645
        let resolvedEos = token2id["<|endoftext|>"] ?? resolvedImEnd
        let resolvedPad = token2id["<|pad|>"] ?? resolvedEos
        let resolvedAudio = token2id["<|audio_pad|>"] ?? 151671
        self.imEndTokenId = resolvedImEnd
        self.eosTokenId = resolvedEos
        self.padTokenId = resolvedPad
        self.audioTokenId = resolvedAudio

        specialIds.insert(resolvedImEnd)
        specialIds.insert(resolvedEos)
        specialIds.insert(resolvedPad)
        if let imStart = token2id["<|im_start|>"] {
            specialIds.insert(imStart)
        }
    }

    public func tokenId(for token: String) -> Int32? {
        token2id[token]
    }

    public func encode(_ text: String) -> [Int32] {
        guard !text.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        var out: [Int32] = []
        var pos = 0
        var last = 0
        while pos < bytes.count {
            var (mlen, tidx) = matchAdded(bytes, at: pos)
            if mlen > 0 && tidx >= 0 && addedTokens[tidx].singleWord &&
                !isSingleWordBoundary(bytes, start: pos, end: pos + mlen) {
                mlen = 0
                tidx = -1
            }
            if mlen > 0 && tidx >= 0 {
                if pos > last {
                    let sub = String(decoding: bytes[last..<pos], as: UTF8.self)
                    encodeSegment(sub, into: &out)
                }
                out.append(addedTokens[tidx].id)
                pos += mlen
                last = pos
                continue
            }
            pos += 1
        }
        if last < bytes.count {
            let sub = String(decoding: bytes[last..<bytes.count], as: UTF8.self)
            encodeSegment(sub, into: &out)
        }
        return out
    }

    public func decode(_ ids: [Int32], skipSpecialTokens: Bool = true) -> String {
        guard !ids.isEmpty else { return "" }
        var rawBytes: [UInt8] = []
        rawBytes.reserveCapacity(ids.count * 4)
        for v in ids {
            let idx = Int(v)
            guard idx >= 0 && idx < id2token.count else { continue }
            if skipSpecialTokens && specialIds.contains(v) { continue }
            let piece = id2token[idx]
            decodeRawBytes(piece, into: &rawBytes)
        }
        return String(decoding: rawBytes, as: UTF8.self)
    }

    // MARK: - Private helpers

    private func buildBytesToUnicode() {
        var bs: [UInt32] = []
        bs.reserveCapacity(256)
        for c in UInt32(33)...UInt32(126) { bs.append(c) }
        for c in UInt32(161)...UInt32(172) { bs.append(c) }
        for c in UInt32(174)...UInt32(255) { bs.append(c) }
        var cs = bs
        var n: UInt32 = 0
        let present = Set(bs)
        for b in UInt32(0)...UInt32(255) {
            if !present.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        for i in 0..<bs.count {
            let scalar = UnicodeScalar(cs[i])!
            byteToUnicode[Int(bs[i])] = String(scalar)
            if cs[i] < 512 {
                cpToByte[Int(cs[i])] = Int16(bs[i])
            }
        }
    }

    /// Reads only the `"added_tokens": [...]` header slice from Hugging Face `tokenizer.json`
    /// instead of deserializing the entire ~11 MB file (which also duplicates `vocab.json` & `merges.txt`).
    private static func readAddedTokens(from url: URL) -> [[String: Any]] {
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            if let headData = try? fh.read(upToCount: 65_536),
               let keyRange = headData.range(of: Data("\"added_tokens\"".utf8)) {
                var idx = keyRange.upperBound
                while idx < headData.endIndex && headData[idx] != UInt8(ascii: "[") {
                    idx += 1
                }
                if idx < headData.endIndex {
                    let arrayStart = idx
                    var depth = 0
                    var inString = false
                    var escaped = false
                    while idx < headData.endIndex {
                        let b = headData[idx]
                        if inString {
                            if escaped {
                                escaped = false
                            } else if b == UInt8(ascii: "\\") {
                                escaped = true
                            } else if b == UInt8(ascii: "\"") {
                                inString = false
                            }
                        } else {
                            if b == UInt8(ascii: "\"") {
                                inString = true
                            } else if b == UInt8(ascii: "[") {
                                depth += 1
                            } else if b == UInt8(ascii: "]") {
                                depth -= 1
                                if depth == 0 {
                                    let slice = headData[arrayStart...idx]
                                    if let parsed = try? JSONSerialization.jsonObject(with: slice) as? [[String: Any]] {
                                        return parsed
                                    }
                                    break
                                }
                            }
                        }
                        idx += 1
                    }
                }
            }
        }
        // Safe fallback if added_tokens is unusually large or located later in the file
        guard let fullData = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: fullData) as? [String: Any],
              let rawAdded = root["added_tokens"] as? [[String: Any]] else {
            return []
        }
        return rawAdded
    }

    private func parseMerges(_ text: String) {
        mergesRank.reserveCapacity(155_000)
        var rank: Int32 = 0
        text.utf8.withContiguousStorageIfAvailable { buf in
            let n = buf.count
            var i = 0
            while i < n {
                var lineEnd = i
                while lineEnd < n && buf[lineEnd] != 0x0A { lineEnd += 1 }
                var trimEnd = lineEnd
                while trimEnd > i && (buf[trimEnd - 1] == 0x0D || buf[trimEnd - 1] == 0x20 || buf[trimEnd - 1] == 0x09) {
                    trimEnd -= 1
                }
                var trimStart = i
                while trimStart < trimEnd && (buf[trimStart] == 0x20 || buf[trimStart] == 0x09) {
                    trimStart += 1
                }
                if trimStart < trimEnd && buf[trimStart] != 0x23 { // skip #version comment
                    var sp = trimStart
                    while sp < trimEnd && buf[sp] != 0x20 { sp += 1 }
                    if sp > trimStart && sp + 1 < trimEnd {
                        var bStart = sp + 1
                        while bStart < trimEnd && buf[bStart] == 0x20 { bStart += 1 }
                        if bStart < trimEnd {
                            let aLen = sp - trimStart
                            let bLen = trimEnd - bStart
                            var keyBytes = [UInt8](repeating: 0, count: aLen + 1 + bLen)
                            for k in 0..<aLen { keyBytes[k] = buf[trimStart + k] }
                            keyBytes[aLen] = 0x09 // '\t'
                            for k in 0..<bLen { keyBytes[aLen + 1 + k] = buf[bStart + k] }
                            let key = String(decoding: keyBytes, as: UTF8.self)
                            self.mergesRank[key] = rank
                            rank += 1
                        }
                    }
                }
                i = lineEnd + 1
            }
        } ?? {
            text.enumerateLines { line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#version") { return }
                guard let sp = trimmed.firstIndex(of: " ") else { return }
                let a = trimmed[..<sp]
                let b = trimmed[trimmed.index(after: sp)...].trimmingCharacters(in: .whitespaces)
                guard !a.isEmpty && !b.isEmpty else { return }
                self.mergesRank["\(a)\t\(b)"] = rank
                rank += 1
            }
        }()
    }

    private func matchAdded(_ bytes: [UInt8], at pos: Int) -> (Int, Int) {
        var node = 0
        var bestIdx = -1
        var bestLen = 0
        var i = pos
        while i < bytes.count {
            guard let nxt = trie[node].next[bytes[i]] else { break }
            node = nxt
            if trie[node].tokenIndex >= 0 {
                bestIdx = trie[node].tokenIndex
                bestLen = i + 1 - pos
            }
            i += 1
        }
        return (bestLen, bestIdx)
    }

    private func isSingleWordBoundary(_ bytes: [UInt8], start: Int, end: Int) -> Bool {
        if start > 0 {
            var s = start - 1
            while s > 0 && (bytes[s] & 0xC0) == 0x80 { s -= 1 }
            let ch = String(decoding: bytes[s..<start], as: UTF8.self)
            if let scalar = ch.unicodeScalars.first, isWordScalar(scalar) {
                return false
            }
        }
        if end < bytes.count {
            var e = end + 1
            while e < bytes.count && (bytes[e] & 0xC0) == 0x80 { e += 1 }
            let ch = String(decoding: bytes[end..<e], as: UTF8.self)
            if let scalar = ch.unicodeScalars.first, isWordScalar(scalar) {
                return false
            }
        }
        return true
    }

    private func isWordScalar(_ s: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(s) || s == "_"
    }

    private func encodeSegment(_ seg: String, into out: inout [Int32]) {
        for piece in splitByQwen3Pattern(seg) {
            var bl = ""
            bl.reserveCapacity(piece.utf8.count * 2)
            for b in piece.utf8 {
                bl.append(byteToUnicode[Int(b)])
            }
            for bt in bpe(bl) {
                if let tid = token2id[bt] {
                    out.append(tid)
                }
            }
        }
    }

    private func bpe(_ word: String) -> [String] {
        cacheLock.lock()
        if let cached = bpeCache[word] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var syms = word.unicodeScalars.map { String($0) }
        while syms.count > 1 {
            var bestRank = Int32.max
            var bestPos = -1
            for i in 0..<(syms.count - 1) {
                let key = "\(syms[i])\t\(syms[i + 1])"
                if let r = mergesRank[key], r < bestRank {
                    bestRank = r
                    bestPos = i
                }
            }
            if bestPos < 0 { break }
            syms[bestPos] += syms[bestPos + 1]
            syms.remove(at: bestPos + 1)
        }

        cacheLock.lock()
        if bpeCache.count > 32_768 {
            bpeCache.removeAll(keepingCapacity: true)
        }
        bpeCache[word] = syms
        cacheLock.unlock()
        return syms
    }

    private func decodeRawBytes(_ merged: String, into out: inout [UInt8]) {
        for scalar in merged.unicodeScalars {
            let cp = Int(scalar.value)
            if cp < 512 && cpToByte[cp] >= 0 {
                out.append(UInt8(cpToByte[cp]))
            } else {
                out.append(contentsOf: String(scalar).utf8)
            }
        }
    }

    /// Implements the exact Qwen2/Qwen3 GPT-4 pre-tokenization regex:
    /// `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+`
    private func splitByQwen3Pattern(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var out: [String] = []
        var i = 0

        func isLetter(_ s: UnicodeScalar) -> Bool {
            CharacterSet.letters.contains(s)
        }
        func isNumber(_ s: UnicodeScalar) -> Bool {
            CharacterSet.decimalDigits.contains(s) || CharacterSet.symbols.contains(s) && s.properties.numericType != nil
        }
        func isNewline(_ s: UnicodeScalar) -> Bool {
            s == "\r" || s == "\n"
        }
        func isWhitespace(_ s: UnicodeScalar) -> Bool {
            s.properties.isWhitespace || isNewline(s)
        }
        func isPunctLike(_ s: UnicodeScalar) -> Bool {
            !isWhitespace(s) && !isLetter(s) && !isNumber(s)
        }
        func slice(_ a: Int, _ b: Int) -> String {
            var str = ""
            str.unicodeScalars.append(contentsOf: scalars[a..<b])
            return str
        }

        while i < n {
            let s = scalars[i]

            // 1. Contractions: (?i:'s|'t|'re|'ve|'m|'ll|'d)
            if s == "'" && i + 1 < n {
                let c1 = Character(scalars[i + 1]).lowercased()
                if c1 == "s" || c1 == "t" || c1 == "m" || c1 == "d" {
                    out.append(slice(i, i + 2))
                    i += 2
                    continue
                }
                if i + 2 < n {
                    let pair = c1 + Character(scalars[i + 2]).lowercased()
                    if pair == "re" || pair == "ve" || pair == "ll" {
                        out.append(slice(i, i + 3))
                        i += 3
                        continue
                    }
                }
            }

            // 2. [^\r\n\p{L}\p{N}]?\p{L}+
            if isLetter(s) {
                var j = i + 1
                while j < n && isLetter(scalars[j]) { j += 1 }
                out.append(slice(i, j))
                i = j
                continue
            }
            if !isNewline(s) && !isNumber(s) && i + 1 < n && isLetter(scalars[i + 1]) {
                var j = i + 2
                while j < n && isLetter(scalars[j]) { j += 1 }
                out.append(slice(i, j))
                i = j
                continue
            }

            // 3. Single digit \p{N}
            if isNumber(s) {
                out.append(slice(i, i + 1))
                i += 1
                continue
            }

            // 4.  ?[^\s\p{L}\p{N}]+[\r\n]*
            if s == " " && i + 1 < n && isPunctLike(scalars[i + 1]) {
                var j = i + 2
                while j < n && isPunctLike(scalars[j]) { j += 1 }
                while j < n && isNewline(scalars[j]) { j += 1 }
                out.append(slice(i, j))
                i = j
                continue
            }
            if isPunctLike(s) {
                var j = i + 1
                while j < n && isPunctLike(scalars[j]) { j += 1 }
                while j < n && isNewline(scalars[j]) { j += 1 }
                out.append(slice(i, j))
                i = j
                continue
            }

            // 5. \s*[\r\n]+ | \s+(?!\S) | \s+
            if isWhitespace(s) {
                var j = i
                var sawNewline = false
                while j < n {
                    if isNewline(scalars[j]) {
                        sawNewline = true
                        break
                    }
                    if !isWhitespace(scalars[j]) { break }
                    j += 1
                }
                if sawNewline {
                    while j < n && isNewline(scalars[j]) { j += 1 }
                    out.append(slice(i, j))
                    i = j
                    continue
                }
                var k = i
                while k < n && isWhitespace(scalars[k]) { k += 1 }
                if k == n {
                    out.append(slice(i, n))
                    i = n
                    continue
                }
                if k - i > 1 {
                    // \s+(?!\S) leaves the final whitespace char to attach to the following word
                    out.append(slice(i, k - 1))
                    i = k - 1
                    continue
                }
                out.append(slice(i, k))
                i = k
                continue
            }

            out.append(slice(i, i + 1))
            i += 1
        }
        return out
    }
}
