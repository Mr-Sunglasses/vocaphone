import Foundation

/// The corrections a spell checker will never make, because nothing is
/// misspelled.
///
/// ``TypingCandidates/autocorrection(_:)`` refuses anything shorter than three
/// letters, anything the checker recognises, and anything that only changes
/// case — three rules that are each individually right and that together
/// silently disable the corrections people notice first. "i" is a word. "im",
/// "dont", "cant" and "youre" are all either real words or close enough that
/// the checker declines to guess. So the keyboard typed exactly what the user
/// pressed, forever, while the system keyboard beside it fixed all of them.
///
/// This is the curated answer: a small table, applied ahead of the general
/// path, holding only substitutions where there is no second reading. It stops
/// well short of a style guide — "ok" stays "ok", "thru" stays "thru" — because
/// the moment a table like this starts having opinions it becomes something to
/// fight.
enum ShortWordCorrections {
    /// Lowercase typed form to replacement. The replacement carries its own
    /// capitalization, which is the point for the "I" family.
    static let table: [String: String] = [
        // The one every user notices in the first minute.
        "i": "I",
        "im": "I'm",
        "id": "I'd",
        "ill": "I'll",
        "ive": "I've",

        // Contractions the checker either recognises as other words or has no
        // confident guess for.
        "dont": "don't",
        "doesnt": "doesn't",
        "didnt": "didn't",
        "cant": "can't",
        "couldnt": "couldn't",
        "shouldnt": "shouldn't",
        "wouldnt": "wouldn't",
        "wont": "won't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "hadnt": "hadn't",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyre": "they're",
        "theyve": "they've",
        "theyll": "they'll",
        "theyd": "they'd",
        "weve": "we've",
        "whats": "what's",
        "thats": "that's",
        "wheres": "where's",
        "hows": "how's",
        "whos": "who's",
        "lets": "let's",
        "aint": "ain't",
        "oclock": "o'clock",
    ]

    /// Words deliberately absent, and why, so nobody adds them back:
    ///
    /// - "its" and "it's" are different words and only grammar can tell them
    ///   apart. Correcting either way is wrong half the time.
    /// - "were", "well", "hell", "shell" and "wed" are all ordinary words in
    ///   their own right, and far too common to spend on a contraction.
    ///   "cant" is borderline and kept, because "can't" wins overwhelmingly.
    /// - "shes", "hes" both map to a possessive reading often enough to leave.
    ///
    /// Kept as prose rather than a set: this is a note to the next person, not
    /// a lookup anything performs.
    static func replacement(for typed: String) -> String? {
        table[typed.lowercased()]
    }

    /// Whether this word has an entry at all, which is also the reason the
    /// general path must not run on it: the table's answer is better than
    /// anything the checker would offer.
    static func hasReplacement(for typed: String) -> Bool {
        table[typed.lowercased()] != nil
    }
}
