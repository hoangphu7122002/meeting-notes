import Foundation

/// Display cleanup of caption text (a Swift subset of the pipeline's Tier 1 rules + hallucination phrases).
/// Captions are display-only, so this only formats: NFC, whitespace, special tokens, immediate repeats, a capital
/// first letter, and Whisper's silence boilerplate ("Cảm ơn các bạn đã theo dõi", "Thanks for watching").
public enum CaptionText {
    /// Known silence hallucinations (mirrors `domain/hallucination.py`); a caption that is little more than one of
    /// them is dropped (captions are short, so the "short block" rule of the pipeline always applies).
    public static let hallucinations = [
        "hẹn gặp lại các bạn trong những video tiếp theo", "hẹn gặp lại các bạn trong video tiếp theo",
        "cảm ơn các bạn đã theo dõi", "cám ơn các bạn đã theo dõi", "cảm ơn các bạn đã xem video",
        "hãy subscribe cho kênh", "đăng ký kênh", "đăng kí kênh", "để không bỏ lỡ những video hấp dẫn",
        "like share và subscribe", "ghiền mì gõ", "la la school", "phụ đề bởi", "thực hiện phụ đề",
        "thanks for watching", "thank you for watching", "thank you so much for watching", "please subscribe",
        "like and subscribe", "don't forget to subscribe", "see you in the next video", "subtitles by", "amara.org",
    ]
    static let slackChars = 16
    private static let compactPhrases = hallucinations.map(compact)

    /// Cleaned text, or "" when nothing worth showing is left.
    public static func clean(_ raw: String) -> String {
        var text = raw.precomposedStringWithCanonicalMapping
        text = text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A whole caption in brackets is a sound annotation: "[Music]", "(upbeat music)", "*laughs*".
        if trimmed.range(of: #"^[\[\(\*♪].*[\]\)\*♪]$"#, options: .regularExpression) != nil { return "" }
        text = collapseRepeats(trimmed.split(whereSeparator: \.isWhitespace).map(String.init)).joined(separator: " ")
        text = text.replacingOccurrences(of: #"\s+([,.!?;:…])"#, with: "$1", options: .regularExpression)
        guard !text.isEmpty, !isHallucination(text) else { return "" }
        return capitalizedFirst(text)
    }

    /// True when the text is a known boilerplate phrase plus at most a few letters, or such phrases make up at least
    /// half of it.
    public static func isHallucination(_ text: String) -> Bool {
        let norm = compact(text)
        guard !norm.isEmpty else { return true }
        let found = compactPhrases.filter { norm.contains($0) }
        if found.contains(where: { norm.count <= $0.count + slackChars }) { return true }
        return Double(found.map(\.count).reduce(0, +)) >= 0.5 * Double(norm.count)
    }

    /// Joins caption pieces with single spaces.
    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A word repeated more than twice in a row keeps two copies ("rất rất" is speech); a 2-4 word phrase repeated
    /// right after itself keeps one (decoding loops).
    static func collapseRepeats(_ words: [String]) -> [String] {
        var out: [String] = []
        for word in words {
            out.append(word)
            if out.count >= 3, out.suffix(3).allSatisfy({ fold($0) == fold(word) }) {
                out.removeLast()
                continue
            }
            for size in 2...4 where out.count >= size * 2 {
                let tail = out.suffix(size).map(fold), before = out.suffix(size * 2).prefix(size).map(fold)
                if tail == before {
                    out.removeLast(size)
                    break
                }
            }
        }
        return out
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func fold(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func compact(_ text: String) -> String {
        let lowered = text.lowercased().precomposedStringWithCanonicalMapping
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
