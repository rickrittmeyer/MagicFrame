import Foundation

/// Maps canonical `objectKey` values to Vision classification labels / identifiers.
enum ObjectVisionLabelMatcher: Sendable {

    nonisolated static func matchers(for objectKey: String) -> [String] {
        let normalizedKey = objectKey.lowercased()
        let builtIn = builtInMatchers[normalizedKey] ?? []
        if !builtIn.isEmpty {
            return builtIn
        }

        let display = OccasionObjectKeyFormatter.displayName(from: objectKey).lowercased()
        let spaced = normalizedKey.replacingOccurrences(of: "_", with: " ")
        return Array(Set([display, spaced, normalizedKey].filter { !$0.isEmpty }))
    }

    nonisolated static func matches(
        objectKey: String,
        classificationIdentifier: String,
        minConfidence: Float
    ) -> Float? {
        let identifier = classificationIdentifier.lowercased()
        let matchers = matchers(for: objectKey)
        guard matchers.contains(where: { identifierMatches(identifier, matcher: $0) }) else {
            return nil
        }
        return minConfidence
    }

    nonisolated private static func identifierMatches(_ identifier: String, matcher: String) -> Bool {
        let matcher = matcher.lowercased()
        if identifier.contains(matcher) {
            return true
        }

        let identifierSpaced = identifier.replacingOccurrences(of: "_", with: " ")
        let matcherSpaced = matcher.replacingOccurrences(of: "_", with: " ")
        if identifierSpaced.contains(matcherSpaced) {
            return true
        }

        let identifierUnderscored = identifier.replacingOccurrences(of: " ", with: "_")
        let matcherUnderscored = matcher.replacingOccurrences(of: " ", with: "_")
        return identifierUnderscored.contains(matcherUnderscored)
    }

    nonisolated private static let builtInMatchers: [String: [String]] = [
        "christmas_tree": ["christmas tree", "christmas_tree", "christmas-tree", "yule", "fir", "spruce", "pine"],
        "ornament": ["ornament", "bauble", "christmas ball", "christmas ornament"],
        "santa": ["santa", "santa claus", "santa_claus", "father christmas"],
        // Vision has no `santa_hat` class; closest taxonomy hits are below.
        "santa_hat": [
            "santa hat",
            "santa_hat",
            "santa-hat",
            "santa_claus",
            "christmas_decoration",
            "costume",
        ],
        "pumpkin": ["pumpkin", "gourd", "squash"],
        "jack_o_lantern": ["jack-o-lantern", "jack o lantern", "jack_o_lantern", "carved pumpkin"],
        "costume": ["costume", "mask", "disguise"],
        "flower": ["flower", "bouquet", "floral", "rose", "tulip", "daisy"],
        "bouquet": ["bouquet", "flower arrangement", "floral arrangement"],
        "gift": ["gift", "present", "wrapped gift", "gift box"],
    ]
}
