import Foundation

/// The answer to a sum typed just before the cursor: "12*4=" offers 48,
/// "1,200/3=" offers 400.
///
/// Arithmetic and nothing else — no units, no currencies, no percentages of
/// anything. Rates go stale, and a keyboard that offers a wrong number with
/// confidence is worse than one that offers none. Nothing here reaches the
/// network; it is a few dozen characters of parsing, run only when the text
/// before the cursor ends in "=".
///
/// The rules are narrow on purpose, so the chip appears for a sum and not for
/// anything that merely contains an equals sign:
///
/// - The sum ends in "=" with nothing after it, and starts at the beginning
///   of the text or after a space, including the one after a sentence's
///   full stop ("Thanks. 3+4="). "x=3+4=" and "$12*4=" are left alone.
/// - At least one operator: + - * / × ÷ −, with parentheses and spaces
///   allowed between the numbers.
/// - Numbers use "." for decimals and "," only to group thousands. "1,5" is
///   ambiguous between locales, so it is not a number here at all.
enum InlineArithmetic {
    /// The longest sum looked at, in characters, which bounds the work on the
    /// keystroke path.
    static let maximumLength = 64

    /// The formatted result for the sum ending `documentBefore`, or nil.
    static func result(before documentBefore: String?) -> String? {
        guard let documentBefore, documentBefore.last == "=" else { return nil }
        // Walk back over characters a sum can contain, without reading the
        // rest of the document.
        var characters: [Character] = []
        var index = documentBefore.index(before: documentBefore.endIndex)
        while index > documentBefore.startIndex {
            let previous = documentBefore.index(before: index)
            let character = documentBefore[previous]
            guard isSumCharacter(character) else { break }
            characters.append(character)
            guard characters.count <= maximumLength else { return nil }
            index = previous
        }
        // The walk also took any comma and spaces in front of the sum — the
        // ones in "Well, 3+4=" — so those come off first. What sits right
        // before the first number then has to be a boundary: a space, or the
        // start of the text. A letter, "$" or "=" there means this is not a
        // sum on its own.
        var run = String(characters.reversed())
        // A full stop and a space end a sentence, never a number — a decimal
        // point has a digit after it — so "Thanks. 3+4=" is a sum starting
        // after the space. The full stop is a sum character, which is why the
        // walk took it and why it has to come off here.
        var startsAfterSentence = false
        if let stop = run.range(of: ". ", options: .backwards) {
            run = String(run[stop.upperBound...])
            startsAfterSentence = true
        }
        let expression = run.drop { $0 == " " || $0 == "," }
        guard !expression.isEmpty else { return nil }
        if startsAfterSentence {
            // Already after a space.
        } else if expression.count < run.count {
            guard run[run.index(run.startIndex, offsetBy: run.count - expression.count - 1)] == " "
            else { return nil }
        } else if index > documentBefore.startIndex {
            let stopper = documentBefore[documentBefore.index(before: index)]
            guard stopper.isWhitespace else { return nil }
        }
        return evaluate(String(expression))
    }

    /// Parses and evaluates one expression, formatted for insertion.
    static func evaluate(_ expression: String) -> String? {
        var parser = Parser(Array(expression))
        guard let value = parser.parseSum(),
              parser.isAtEnd,
              parser.operatorCount > 0,
              value.isFinite
        else { return nil }
        return format(value, grouped: parser.sawGrouping)
    }

    /// Whole numbers without a decimal point, others to at most six places
    /// with trailing zeros dropped. Grouped with commas when the sum was.
    static func format(_ value: Double, grouped: Bool) -> String? {
        guard abs(value) < 1e15 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouped
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.roundingMode = .halfUp
        // -0.0000001 rounds to "-0"; zero has no sign.
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return formatter.string(from: NSNumber(value: rounded == 0 ? 0 : rounded))
    }

    private static func isSumCharacter(_ character: Character) -> Bool {
        if character.isASCII, character.isNumber { return true }
        return " .,+-*/×÷−()".contains(character)
    }

    /// Recursive descent over `sum := product (('+'|'-') product)*`,
    /// `product := factor (('*'|'/') factor)*`,
    /// `factor := '-'? (number | '(' sum ')')`.
    private struct Parser {
        let characters: [Character]
        var position = 0
        var operatorCount = 0
        var sawGrouping = false
        var depth = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        var isAtEnd: Bool {
            var probe = self
            probe.skipSpaces()
            return probe.position == characters.count
        }

        mutating func skipSpaces() {
            while position < characters.count, characters[position] == " " { position += 1 }
        }

        mutating func peekOperator() -> Character? {
            skipSpaces()
            guard position < characters.count else { return nil }
            return characters[position]
        }

        mutating func parseSum() -> Double? {
            guard var value = parseProduct() else { return nil }
            while let op = peekOperator(), op == "+" || op == "-" || op == "−" {
                position += 1
                guard let right = parseProduct() else { return nil }
                value = op == "+" ? value + right : value - right
                operatorCount += 1
            }
            return value
        }

        mutating func parseProduct() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peekOperator(), "*×/÷".contains(op) {
                position += 1
                guard let right = parseFactor() else { return nil }
                if op == "*" || op == "×" {
                    value *= right
                } else {
                    guard right != 0 else { return nil }
                    value /= right
                }
                operatorCount += 1
            }
            return value
        }

        mutating func parseFactor() -> Double? {
            skipSpaces()
            guard position < characters.count else { return nil }
            let character = characters[position]
            if character == "-" || character == "−" {
                position += 1
                return parseFactor().map { -$0 }
            }
            if character == "(" {
                // Bounded, so a run of brackets cannot recurse without limit.
                guard depth < 8 else { return nil }
                position += 1
                depth += 1
                defer { depth -= 1 }
                guard let value = parseSum() else { return nil }
                skipSpaces()
                guard position < characters.count, characters[position] == ")" else { return nil }
                position += 1
                return value
            }
            return parseNumber()
        }

        /// Digits, optionally grouped in threes by commas, optionally with a
        /// decimal part. A comma anywhere else ends the parse in failure.
        mutating func parseNumber() -> Double? {
            var integer = ""
            var groups: [String] = []
            var current = ""
            while position < characters.count {
                let character = characters[position]
                if character.isASCII, character.isNumber {
                    current.append(character)
                } else if character == "," {
                    groups.append(current)
                    current = ""
                } else {
                    break
                }
                position += 1
            }
            groups.append(current)
            if groups.count > 1 {
                // "1,200" and "12,345,678": a first group of one to three
                // digits, then groups of exactly three.
                guard let first = groups.first, (1...3).contains(first.count),
                      groups.dropFirst().allSatisfy({ $0.count == 3 })
                else { return nil }
                sawGrouping = true
            }
            integer = groups.joined()
            var fraction = ""
            if position < characters.count, characters[position] == "." {
                position += 1
                while position < characters.count, characters[position].isASCII, characters[position].isNumber {
                    fraction.append(characters[position])
                    position += 1
                }
                guard !fraction.isEmpty else { return nil }
            }
            guard !integer.isEmpty || !fraction.isEmpty else { return nil }
            return Double((integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction))
        }
    }
}
