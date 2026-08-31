import Foundation

/// Arama esleyici. Duz metin ICERIR olarak arar; `*` varsa joker olarak
/// yorumlar: `*jpg` sonu jpg, `jpg*` basi jpg, `a*b` a ile baslayip b ile biten.
enum SearchMatch {

    /// Sorgu bos ise her sey eslesir.
    static func matches(_ query: String, _ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let t = text.lowercased()
        guard q.contains("*") else { return t.contains(q) }

        // Joker: parcalara ayirip sirayla ara.
        let parts = q.components(separatedBy: "*")
        var idx = t.startIndex

        // Basta joker yoksa metin o parcayla BASLAMALI
        if let first = parts.first, !first.isEmpty {
            guard t.hasPrefix(first) else { return false }
            idx = t.index(idx, offsetBy: first.count)
        }
        // Sonda joker yoksa metin son parcayla BITMELI
        if let last = parts.last, !last.isEmpty {
            guard t.hasSuffix(last) else { return false }
        }
        // Ortadaki parcalar sirayla gecmeli
        let middle = parts.dropFirst().dropLast()
        for p in middle where !p.isEmpty {
            guard let r = t.range(of: p, range: idx..<t.endIndex) else { return false }
            idx = r.upperBound
        }
        // Son parca, ilerlemenin gerisinde kalmamali
        if parts.count > 1, let last = parts.last, !last.isEmpty {
            guard let r = t.range(of: last, options: .backwards), r.lowerBound >= idx
            else { return parts.count == 2 && parts.first!.isEmpty }
        }
        return true
    }

    /// Birden fazla alandan herhangi biri eslesirse true.
    static func matchesAny(_ query: String, _ fields: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fields.contains { matches(q, $0) }
    }
}
