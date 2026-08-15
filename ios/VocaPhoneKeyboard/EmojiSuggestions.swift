import Foundation

/// The emoji offered for a word as it is typed: "lol" offers 😂.
///
/// A curated table rather than a lookup into ``EmojiCatalog``, which was the
/// obvious idea and is the wrong one. The catalog's keywords exist to answer a
/// deliberate search in the emoji panel, where the user has typed a query and
/// is looking at a grid of results. Matched against ordinary prose it answers
/// "the" with 🤣, "and" with 🫢, "is" with the flag of Iceland, "dog" with 💩
/// and "clock" with 🏫 — because a keyword match says a word appears somewhere
/// in an emoji's description, not that the emoji is what the word means.
///
/// So this is a hand-checked map of word to the one emoji a reader would expect,
/// and a word that is not in it produces nothing. Everyday prose has to pass
/// through the strip untouched: the cost of a wrong suggestion is not a wrong
/// character — the chip has to be tapped — but a strip that cries wolf on every
/// third word is one nobody reads, including when it is right.
///
/// Words are excluded when they are common in ordinary sentences without
/// carrying the thing the emoji means: "good", "yes", "no", "time", "work",
/// "day", "code", "check", "key". The bar is whether the emoji is the *obvious*
/// association, not merely *an* association.
///
/// English only, matching the rest of the typing intelligence. It costs a few
/// kilobytes, which is the other reason it is not the catalog: the keyboard is
/// killed around 45–60 MB, and the 284 KB catalog is loaded only when the emoji
/// panel is actually opened.
enum EmojiSuggestions {
    /// The shortest word worth matching. Two letters are mostly initials,
    /// particles and typos.
    static let minimumLength = 2

    static func glyph(for word: String) -> String? {
        let key = word.lowercased()
        guard key.count >= minimumLength else { return nil }
        return triggers[key]
    }

    /// Exact whole words only. A prefix match would put an emoji on the strip
    /// while the user is still two letters into a different word.
    static let triggers: [String: String] = [
        // Laughter and reactions — the vocabulary of a chat keyboard, which is
        // where this feature earns its slot.
        "lol": "😂", "lmao": "🤣", "rofl": "🤣", "haha": "😂", "hehe": "😄",
        "funny": "😂", "omg": "😱", "wow": "😮", "yay": "🎉", "oops": "🙈",
        "ugh": "😩", "meh": "😐", "cool": "😎", "nice": "👍", "awesome": "🤩",
        "amazing": "🤩", "perfect": "👌", "done": "✅", "agree": "👍",
        "congrats": "🎉", "congratulations": "🎉", "welcome": "🤗",

        // Feeling
        "love": "❤️", "loved": "❤️", "heart": "❤️", "happy": "😊", "sad": "😢",
        "cry": "😭", "crying": "😭", "angry": "😠", "mad": "😠", "tired": "😴",
        "sleepy": "😴", "sleep": "😴", "sick": "🤒", "scared": "😱",
        "confused": "😕", "bored": "🥱", "excited": "🤩", "shy": "😊",
        "hungry": "😋", "thirsty": "🥤", "stressed": "😰", "relieved": "😌",

        // Greetings and courtesies
        "hi": "👋", "hello": "👋", "hey": "👋", "bye": "👋", "goodbye": "👋",
        "thanks": "🙏", "thankyou": "🙏", "please": "🙏", "sorry": "😔",
        "hug": "🤗", "hugs": "🤗", "kiss": "😘", "wink": "😉",

        // Gestures
        "ok": "👌", "okay": "👌", "clap": "👏", "applause": "👏", "bravo": "👏",
        "wave": "👋", "pray": "🙏", "prayers": "🙏", "muscle": "💪",
        "strong": "💪", "facepalm": "🤦", "shrug": "🤷", "thinking": "🤔",
        "eyes": "👀", "brain": "🧠",

        // Things that are simply themselves
        "fire": "🔥", "lit": "🔥", "skull": "💀", "ghost": "👻", "alien": "👽",
        "robot": "🤖", "poop": "💩", "party": "🎉", "birthday": "🎂",
        "cake": "🎂", "gift": "🎁", "present": "🎁", "balloon": "🎈",
        "fireworks": "🎆", "crown": "👑", "diamond": "💎", "trophy": "🏆",
        "winner": "🏆", "medal": "🥇", "idea": "💡", "bug": "🐛",
        "warning": "⚠️", "rocket": "🚀",

        // Food and drink
        "pizza": "🍕", "burger": "🍔", "fries": "🍟", "coffee": "☕",
        "tea": "🍵", "beer": "🍺", "wine": "🍷", "water": "💧",
        "breakfast": "🥞", "lunch": "🍽️", "dinner": "🍽️", "snack": "🍿",
        "chocolate": "🍫", "cookie": "🍪", "icecream": "🍦", "apple": "🍎",
        "banana": "🍌", "biryani": "🍛", "chai": "🍵",

        // Living things and weather
        "dog": "🐶", "puppy": "🐶", "cat": "🐱", "kitten": "🐱", "bird": "🐦",
        "fish": "🐟", "tree": "🌳", "flower": "🌸", "rose": "🌹",
        "sun": "☀️", "sunny": "☀️", "moon": "🌙", "star": "⭐",
        "rain": "🌧️", "rainy": "🌧️", "snow": "❄️", "storm": "⛈️",
        "rainbow": "🌈", "beach": "🏖️",

        // Places, travel, the working day
        "home": "🏠", "house": "🏠", "office": "🏢", "school": "🏫",
        "hospital": "🏥", "bank": "🏦", "gym": "🏋️", "workout": "🏋️",
        "running": "🏃", "walk": "🚶", "travel": "✈️", "vacation": "✈️",
        "holiday": "✈️", "flight": "✈️", "plane": "✈️", "airport": "✈️",
        "car": "🚗", "train": "🚆", "bike": "🚲", "shopping": "🛒",
        "money": "💰", "cash": "💰", "salary": "💰",

        // Objects people mention in messages
        "music": "🎵", "song": "🎵", "book": "📚", "reading": "📚",
        "phone": "📱", "laptop": "💻", "computer": "💻", "email": "📧",
        "mail": "📧", "calendar": "📅", "meeting": "🗓️", "deadline": "⏰",
        "clock": "⏰", "alarm": "⏰", "camera": "📷", "photo": "📷",
        "movie": "🎬", "game": "🎮", "gaming": "🎮", "art": "🎨",
        "football": "⚽", "cricket": "🏏", "basketball": "🏀",

        // Occasions
        "christmas": "🎄", "halloween": "🎃", "diwali": "🪔",
    ]
}
