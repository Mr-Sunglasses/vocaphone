package com.vocahq.vocaphone.ime

/**
 * Geometry and scoring for swipe / glide typing.
 *
 * The finger's path is a sequence of *apexes*: start, each place it
 * changes direction, end. Around every apex we take the keys within
 * reach and walk the dictionary as a letter tree — a word is a candidate
 * only if its letters cover those apexes in order. That is why a four-key
 * swipe of "what" cannot become a nine-letter word that merely shares
 * a neighbour of W and T.
 *
 * A flick with no turns is underspecified (W→H). Then start→end plus
 * frequency decide, which is why that gesture is "with".
 *
 * Survivors are ranked `zipf(frequency) − spatial` (shape, letters on
 * the stroke, absolute start/end). The suggestion strip after a swipe
 * is the rest of that same-path list, not edit-distance cousins of the
 * winner.
 */
internal data class SwipeInput(
    val keys: String,
    val points: FloatArray = FloatArray(0),
    val previousWord: String = "",
)

internal object SwipeLayout {
    data class XY(val x: Float, val y: Float) {
        fun distanceTo(other: XY): Float {
            val dx = x - other.x
            val dy = y - other.y
            return kotlin.math.sqrt(dx * dx + dy * dy)
        }
    }

    const val SAMPLE_POINTS = 24

    /**
     * How far a finger can sit from a key centre, in key units, and still
     * count as having meant that letter. ~0.85 is inside the next key's
     * edge without swallowing a whole extra column.
     */
    const val LETTER_ON_PATH_RADIUS = 0.85f

    /** Neighbour radius used for tap corrections and swipe end-key slack. */
    const val NEIGHBOUR_RADIUS = 1.55f

    const val MAX_TRACE_POINTS = 96

    /** Mean keyboard-unit error against the best template. */
    private const val LOCATION_WEIGHT = 2.2f

    /** Mean error after bbox-normalising both paths (shape, not place). */
    private const val SHAPE_WEIGHT = 3.4f

    /** Mean distance of each letter of the word to the stroke, in order. */
    private const val LETTER_WEIGHT = 1.6f

    /**
     * Start and end keys vs the stroke's actual ends. These are the strongest
     * spatial signal and must not be diluted across the resampled middle.
     */
    private const val END_WEIGHT = 1.7f

    /**
     * Zipf is ~9 nats for rank 0 on a 10k list. This scale keeps one key of
     * spatial mismatch ahead of a large frequency gap, while still letting
     * "the" beat "te" on a straight T→E swipe.
     */
    private const val FREQ_WEIGHT = 0.30f

    private const val CONTEXT_BONUS = 0.45f

    /**
     * Ramer–Douglas–Peucker epsilon in key units. Below this, a bump is
     * still the same segment; above it, the finger turned.
     */
    const val APEX_EPSILON = 0.8f

    /** Keys around a turn. Tighter than start/end so a corner on H is not N. */
    const val CORNER_RADIUS = 1.05f

    /**
     * A swipe starts only when the finger enters a *different letter key's
     * rectangle*. Nearest-key must not decide this: a tap near an edge flips
     * nearest within a few pixels, undoes the seed letter that went out on
     * pointer down, and one-shot shift (sentence capitals) dies with it.
     */
    fun enteredAnotherLetter(startId: String, hitId: String?): Boolean =
        hitId != null && hitId != startId

    val QWERTY: Map<Char, XY> = buildMap {
        fun row(y: Float, startX: Float, letters: String) {
            letters.forEachIndexed { index, letter -> put(letter, XY(startX + index, y)) }
        }
        row(0f, 0f, "qwertyuiop")
        row(1f, 0.5f, "asdfghjkl")
        row(2f, 1.5f, "zxcvbnm")
    }

    val NEARBY: Map<Char, Set<Char>> = QWERTY.mapValues { (letter, origin) ->
        QWERTY.entries
            .filter { (other, point) -> other != letter && origin.distanceTo(point) < NEIGHBOUR_RADIUS }
            .map { it.key }
            .toSet()
    }

    private val REACH: IntArray = IntArray(26) { offset ->
        val letter = 'a' + offset
        letterBits(NEARBY[letter].orEmpty() + letter)
    }

    fun nearby(letter: Char): Set<Char> = NEARBY[letter].orEmpty()

    fun qwerty(letter: Char): XY? = QWERTY[letter]

    fun lettersAround(point: XY, radius: Float): Set<Char> =
        QWERTY.filter { (_, origin) -> origin.distanceTo(point) <= radius }.keys

    fun letterMaskAround(point: XY, radius: Float): Int {
        var mask = 0
        for ((letter, origin) in QWERTY) {
            if (origin.distanceTo(point) <= radius) mask = mask or SuggestionEngine.letterBit(letter)
        }
        return mask
    }

    /**
     * Start, direction changes, end. A straight flick stays two points;
     * W→H→A→T keeps all four because H and A sit off the start-end line.
     */
    fun simplify(points: FloatArray, epsilon: Float = APEX_EPSILON): List<XY> {
        val n = points.size / 2
        if (n <= 0) return emptyList()
        val pts = ArrayList<XY>(n)
        var i = 0
        while (i + 1 < points.size) {
            pts.add(XY(points[i], points[i + 1]))
            i += 2
        }
        if (pts.size <= 2) return pts
        val keep = BooleanArray(pts.size)
        keep[0] = true
        keep[pts.lastIndex] = true
        fun rdp(lo: Int, hi: Int) {
            if (hi - lo < 2) return
            val from = pts[lo]
            val to = pts[hi]
            var farthest = 0f
            var farthestAt = lo
            var index = lo + 1
            while (index < hi) {
                val d = distanceToSegment(pts[index], from, to)
                if (d > farthest) {
                    farthest = d
                    farthestAt = index
                }
                index++
            }
            if (farthest > epsilon) {
                keep[farthestAt] = true
                rdp(lo, farthestAt)
                rdp(farthestAt, hi)
            }
        }
        rdp(0, pts.lastIndex)
        val out = ArrayList<XY>(pts.size)
        for (index in pts.indices) if (keep[index]) out.add(pts[index])
        return out
    }

    /**
     * Bitmask of keys around each apex. Start and end use the neighbour
     * radius; turns use [CORNER_RADIUS] so the keys *at the turn* matter.
     */
    fun apexMasks(waypoints: List<XY>): IntArray {
        if (waypoints.isEmpty()) return IntArray(0)
        val masks = IntArray(waypoints.size)
        masks[0] = letterMaskAround(waypoints.first(), NEIGHBOUR_RADIUS)
        if (waypoints.size > 1) {
            masks[waypoints.lastIndex] = letterMaskAround(waypoints.last(), NEIGHBOUR_RADIUS)
        }
        for (index in 1 until waypoints.lastIndex) {
            masks[index] = letterMaskAround(waypoints[index], CORNER_RADIUS)
        }
        return masks
    }

    /**
     * Whether [compact] can explain the apexes: first letter on the start
     * set, last letter on the end set, and every apex hit in order. Extra
     * letters in the word are allowed (fly-overs, silent interiors). One
     * letter may cover consecutive apexes when it sits in both key sets
     * (a start that landed on a neighbour of the first turn).
     */
    fun coversApexes(compact: String, masks: IntArray): Boolean {
        if (compact.length < 2 || masks.size < 2) return false
        if (SuggestionEngine.letterBit(compact.first()) and masks.first() == 0) return false
        if (SuggestionEngine.letterBit(compact.last()) and masks.last() == 0) return false
        var apex = 0
        for (character in compact) {
            val bit = SuggestionEngine.letterBit(character)
            while (apex < masks.size && (bit and masks[apex]) != 0) {
                apex++
            }
            if (apex == masks.size) return true
        }
        return apex == masks.size
    }

    /**
     * Map a touch that landed [nx], [ny] key-widths from [letter]'s centre
     * into the same unit grid the matcher scores in. A finger that cut the
     * corner of H toward Y is (5.5, 1) + a fraction, not "h" or "y".
     */
    fun gridPoint(letter: Char, nx: Float, ny: Float): XY? {
        val origin = QWERTY[letter] ?: return null
        return XY(origin.x + nx, origin.y + ny)
    }

    fun reachMask(letter: Char): Int {
        val offset = letter - 'a'
        return if (offset in 0..25) REACH[offset] else 0
    }

    fun pathLength(keys: String): Float = polylineLength(keyCentres(keys))

    fun pathLength(points: FloatArray): Float {
        val n = points.size / 2
        if (n < 2) return 0f
        var length = 0f
        var i = 2
        while (i < points.size) {
            val dx = points[i] - points[i - 2]
            val dy = points[i + 1] - points[i - 1]
            length += kotlin.math.sqrt(dx * dx + dy * dy)
            i += 2
        }
        return length
    }

    fun sampleWord(word: String): FloatArray = samplePolyline(keyCentres(word, loops = false))

    fun sampleWordWithLoops(word: String): FloatArray = samplePolyline(keyCentres(word, loops = true))

    fun sampleWordShortcut(word: String): FloatArray = samplePolyline(shortcutCentres(word))

    fun sampleEndpoints(first: Char, last: Char): FloatArray {
        val from = QWERTY[first] ?: return FloatArray(0)
        val to = QWERTY[last] ?: return FloatArray(0)
        return samplePolyline(listOf(from, to))
    }

    fun shortcutLength(word: String): Float = polylineLength(shortcutCentres(word))

    fun samplePoints(points: FloatArray): FloatArray {
        val n = points.size / 2
        if (n == 0) return FloatArray(0)
        val poly = ArrayList<XY>(n)
        var i = 0
        while (i < points.size - 1) {
            poly.add(XY(points[i], points[i + 1]))
            i += 2
        }
        return samplePolyline(poly)
    }

    /**
     * The letters a polyline actually crosses, collapsing consecutive
     * repeats. Tests use this to feed the matcher the same key string a
     * real swipe would have collected.
     */
    fun nearestKeyString(points: FloatArray): String {
        if (points.size < 2) return ""
        val out = StringBuilder()
        var i = 0
        while (i + 1 < points.size) {
            val x = points[i]
            val y = points[i + 1]
            var best: Char? = null
            var bestD = Float.MAX_VALUE
            for ((letter, origin) in QWERTY) {
                val d = origin.distanceTo(XY(x, y))
                if (d < bestD) {
                    bestD = d
                    best = letter
                }
            }
            val letter = best
            if (letter != null && (out.isEmpty() || out.last() != letter)) out.append(letter)
            i += 2
        }
        return out.toString()
    }

    fun interpolate(letters: String, stepsPerSegment: Int = 8): FloatArray {
        val centres = keyCentres(letters, loops = false)
        if (centres.size <= 1) {
            val point = centres.firstOrNull() ?: return FloatArray(0)
            val out = FloatArray(2)
            out[0] = point.x
            out[1] = point.y
            return out
        }
        val out = FloatArray((centres.size - 1) * stepsPerSegment * 2 + 2)
        var w = 0
        for (index in 1 until centres.size) {
            val from = centres[index - 1]
            val to = centres[index]
            for (step in 0 until stepsPerSegment) {
                val t = step / stepsPerSegment.toFloat()
                out[w++] = from.x + (to.x - from.x) * t
                out[w++] = from.y + (to.y - from.y) * t
            }
        }
        val last = centres.last()
        out[w++] = last.x
        out[w] = last.y
        return out
    }

    /**
     * The path a finger actually draws for [word]: skip letters that already
     * lie on the line between earlier waypoints. "with" is W-I-T-H in spelling
     * but T sits on W→I, so people swipe W→I→H and never reverse to T.
     */
    fun shortcutInterpolate(word: String, stepsPerSegment: Int = 10): FloatArray =
        interpolateCentres(shortcutCentres(word), stepsPerSegment)

    private fun shortcutCentres(word: String): List<XY> {
        val centres = keyCentres(word, loops = false)
        if (centres.size <= 2) return centres
        val kept = ArrayList<XY>(centres.size)
        kept.add(centres.first())
        for (index in 1 until centres.lastIndex) {
            if (nearPolyline(centres[index], kept, radius = 0.55f)) continue
            kept.add(centres[index])
        }
        kept.add(centres.last())
        return kept
    }

    private fun interpolateCentres(centres: List<XY>, stepsPerSegment: Int): FloatArray {
        if (centres.size <= 1) {
            val point = centres.firstOrNull() ?: return FloatArray(0)
            return floatArrayOf(point.x, point.y)
        }
        val out = FloatArray((centres.size - 1) * stepsPerSegment * 2 + 2)
        var w = 0
        for (index in 1 until centres.size) {
            val from = centres[index - 1]
            val to = centres[index]
            for (step in 0 until stepsPerSegment) {
                val t = step / stepsPerSegment.toFloat()
                out[w++] = from.x + (to.x - from.x) * t
                out[w++] = from.y + (to.y - from.y) * t
            }
        }
        val last = centres.last()
        out[w++] = last.x
        out[w] = last.y
        return out
    }

    private fun nearPolyline(point: XY, poly: List<XY>, radius: Float): Boolean {
        if (poly.size == 1) return point.distanceTo(poly[0]) <= radius
        for (index in 1 until poly.size) {
            if (distanceToSegment(point, poly[index - 1], poly[index]) <= radius) return true
        }
        return false
    }

    private fun distanceToSegment(point: XY, from: XY, to: XY): Float {
        val dx = to.x - from.x
        val dy = to.y - from.y
        val lengthSq = dx * dx + dy * dy
        val t = if (lengthSq < 1e-9f) {
            0f
        } else {
            (((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSq).coerceIn(0f, 1f)
        }
        return point.distanceTo(XY(from.x + t * dx, from.y + t * dy))
    }

    fun hasDoubleLetter(word: String): Boolean {
        var previous = 0.toChar()
        for (character in word) {
            val letter = character.lowercaseChar()
            if (letter == previous) return true
            if (letter in 'a'..'z') previous = letter
        }
        return false
    }

    /**
     * Every letter of [word] (collapsed) lies near some later segment of the
     * sampled path, in order. OpenSwipe's sequence match: a fly-over does
     * not have to *enter* the key, and a word that needs a key the finger
     * never approached is out.
     */
    fun lettersLieOnPath(word: String, samples: FloatArray, radius: Float = LETTER_ON_PATH_RADIUS): Boolean {
        val n = samples.size / 2
        if (n == 0) return false
        var segment = 0
        var last = 0.toChar()
        for (character in word) {
            if (character !in 'a'..'z' || character == last) continue
            last = character
            val target = QWERTY[character] ?: continue
            var found = false
            while (segment < n - 1) {
                if (distanceToSegment(target, samples, segment) <= radius) {
                    found = true
                    break
                }
                segment++
            }
            if (!found) {
                // Last point itself, for a one-sample leftover.
                val lastX = samples[samples.size - 2]
                val lastY = samples[samples.size - 1]
                if (target.distanceTo(XY(lastX, lastY)) > radius) return false
            }
        }
        return true
    }

    private fun keyCentres(word: String, loops: Boolean = false): List<XY> {
        val points = ArrayList<XY>(word.length + 4)
        var previous = 0.toChar()
        for (character in word) {
            val letter = character.lowercaseChar()
            val centre = QWERTY[letter] ?: continue
            if (loops && letter == previous) {
                // A real double-letter swipe is a scribble around the key, not
                // a quarter-key wiggle that a straight path still matches.
                points.add(XY(centre.x + 0.7f, centre.y + 0.7f))
                points.add(XY(centre.x + 0.7f, centre.y - 0.7f))
                points.add(XY(centre.x - 0.7f, centre.y - 0.7f))
                points.add(XY(centre.x - 0.7f, centre.y + 0.7f))
                points.add(centre)
            } else if (letter != previous) {
                points.add(centre)
            }
            previous = letter
        }
        return points
    }

    private fun polylineLength(points: List<XY>): Float {
        if (points.size < 2) return 0f
        var length = 0f
        for (index in 1 until points.size) length += points[index - 1].distanceTo(points[index])
        return length
    }

    fun samplePolyline(points: List<XY>): FloatArray {
        val count = SAMPLE_POINTS
        if (points.isEmpty()) return FloatArray(0)
        if (points.size == 1 || count <= 1) {
            val out = FloatArray(count * 2)
            val point = points.first()
            for (index in 0 until count) {
                out[index * 2] = point.x
                out[index * 2 + 1] = point.y
            }
            return out
        }
        val prefix = FloatArray(points.size)
        for (index in 1 until points.size) {
            prefix[index] = prefix[index - 1] + points[index - 1].distanceTo(points[index])
        }
        val total = prefix.last().coerceAtLeast(0.0001f)
        val out = FloatArray(count * 2)
        for (sample in 0 until count) {
            val target = total * sample / (count - 1)
            var index = 1
            while (index < prefix.lastIndex && prefix[index] < target) index++
            val start = prefix[index - 1]
            val span = (prefix[index] - start).coerceAtLeast(0.0001f)
            val t = ((target - start) / span).coerceIn(0f, 1f)
            val from = points[index - 1]
            val to = points[index]
            out[sample * 2] = from.x + (to.x - from.x) * t
            out[sample * 2 + 1] = from.y + (to.y - from.y) * t
        }
        return out
    }

    private fun distanceToSegment(point: XY, samples: FloatArray, segment: Int): Float {
        val ax = samples[segment * 2]
        val ay = samples[segment * 2 + 1]
        val bx = samples[segment * 2 + 2]
        val by = samples[segment * 2 + 3]
        val dx = bx - ax
        val dy = by - ay
        val lengthSq = dx * dx + dy * dy
        val t = if (lengthSq < 1e-9f) {
            0f
        } else {
            (((point.x - ax) * dx + (point.y - ay) * dy) / lengthSq).coerceIn(0f, 1f)
        }
        val closestX = ax + t * dx
        val closestY = ay + t * dy
        val ex = point.x - closestX
        val ey = point.y - closestY
        return kotlin.math.sqrt(ex * ex + ey * ey)
    }

    private fun letterBits(letters: Iterable<Char>): Int {
        var mask = 0
        for (letter in letters) mask = mask or SuggestionEngine.letterBit(letter)
        return mask
    }

    /**
     * One gesture. Apex masks are the candidate tree; templates rank
     * the words that cover them.
     */
    internal class Gesture(
        val keys: String,
        points: FloatArray,
    ) {
        private val raw: FloatArray
        private val samples: FloatArray
        private val normalizedSamples: FloatArray
        private val start: XY
        private val end: XY
        private val firstMask: Int
        private val lastMask: Int
        private val waypointMasks: IntArray
        private val endpointCache = arrayOfNulls<FloatArray>(26 * 26)

        /** Two points = a flick. Three or more = the finger turned. */
        val hasTurns: Boolean

        init {
            raw = if (points.size >= 4) points else interpolate(keys)
            samples = samplePoints(raw)
            normalizedSamples = normalize(samples)
            start = if (raw.size >= 2) XY(raw[0], raw[1]) else XY(0f, 0f)
            end = if (raw.size >= 2) {
                XY(raw[raw.size - 2], raw[raw.size - 1])
            } else {
                start
            }
            val waypoints = simplify(raw)
            waypointMasks = apexMasks(waypoints)
            hasTurns = waypoints.size >= 3
            firstMask = if (waypointMasks.isNotEmpty()) {
                waypointMasks.first()
            } else {
                letterBits(nearby(keys.first()) + keys.first())
            }
            lastMask = if (waypointMasks.size > 1) {
                waypointMasks.last()
            } else {
                letterBits(nearby(keys.last()) + keys.last())
            }
        }

        fun endsAreReachable(first: Char, last: Char): Boolean =
            SuggestionEngine.letterBit(first) and firstMask != 0 &&
                SuggestionEngine.letterBit(last) and lastMask != 0

        fun mayBeginWith(letter: Char): Boolean =
            SuggestionEngine.letterBit(letter) and firstMask != 0

        fun coversWord(compact: String): Boolean =
            !hasTurns || coversApexes(compact, waypointMasks)

        fun score(
            compactWord: String,
            originalWord: String,
            frequencyRank: Int,
            wordCount: Int,
            predictedWord: Boolean,
            full: FloatArray,
            shortcut: FloatArray,
        ): Float {
            if (samples.size != SAMPLE_POINTS * 2) return Float.NEGATIVE_INFINITY
            var best = spatialCost(full)
            if (shortcut.size == samples.size) best = minOf(best, spatialCost(shortcut))
            val first = compactWord.first()
            val last = compactWord.last()
            // A start→end template is only a fair drawing of the word when
            // the finger did not turn. Otherwise every W…T word looks like
            // a four-key "what".
            if (!hasTurns) {
                val ends = endpoints(first, last)
                if (ends.size == samples.size) best = minOf(best, spatialCost(ends))
            }
            if (hasDoubleLetter(originalWord)) {
                val looped = sampleWordWithLoops(originalWord)
                if (looped.size == samples.size) best = minOf(best, spatialCost(looped))
            }
            val origin = QWERTY[first]
            val finish = QWERTY[last]
            val endCost = if (origin != null && finish != null) {
                END_WEIGHT * (start.distanceTo(origin) + end.distanceTo(finish))
            } else {
                END_WEIGHT * 2f
            }
            val spatial = best + LETTER_WEIGHT * letterCost(compactWord) + endCost
            val n = wordCount.coerceAtLeast(2)
            val zipf = kotlin.math.ln((n + 1f) / (frequencyRank + 1f))
            val context = if (predictedWord) CONTEXT_BONUS else 0f
            return FREQ_WEIGHT * zipf + context - spatial
        }

        private fun endpoints(first: Char, last: Char): FloatArray {
            val i = first - 'a'
            val j = last - 'a'
            if (i !in 0..25 || j !in 0..25) return sampleEndpoints(first, last)
            val key = i * 26 + j
            endpointCache[key]?.let { return it }
            val sampled = sampleEndpoints(first, last)
            endpointCache[key] = sampled
            return sampled
        }

        private fun spatialCost(template: FloatArray): Float {
            if (template.size != samples.size) return 8f
            return LOCATION_WEIGHT * meanDistance(samples, template) +
                SHAPE_WEIGHT * meanDistance(normalizedSamples, normalize(template))
        }

        /**
         * Mean distance from each unique letter of the word to the closest
         * remaining point on the stroke. Monotonic so a word cannot claim
         * letters out of order; unmatched tail letters sit on the end.
         */
        private fun letterCost(compactWord: String): Float {
            val n = raw.size / 2
            if (n == 0) return 4f
            var segment = 0
            var sum = 0f
            var count = 0
            var previous = 0.toChar()
            for (character in compactWord) {
                if (character !in 'a'..'z' || character == previous) continue
                previous = character
                val target = QWERTY[character] ?: continue
                var best = Float.MAX_VALUE
                var bestSegment = segment
                if (n == 1) {
                    best = target.distanceTo(XY(raw[0], raw[1]))
                } else {
                    var index = segment
                    while (index < n - 1) {
                        val d = distanceToSegment(target, raw, index)
                        if (d < best) {
                            best = d
                            bestSegment = index
                        }
                        index++
                    }
                }
                sum += best
                count++
                segment = bestSegment
            }
            return if (count == 0) 4f else sum / count
        }

        private fun meanDistance(left: FloatArray, right: FloatArray): Float {
            if (left.size != right.size || left.isEmpty()) return Float.MAX_VALUE
            var sum = 0f
            var i = 0
            while (i < left.size) {
                val dx = left[i] - right[i]
                val dy = left[i + 1] - right[i + 1]
                sum += kotlin.math.sqrt(dx * dx + dy * dy)
                i += 2
            }
            return sum / (left.size / 2)
        }

        private fun normalize(points: FloatArray): FloatArray {
            if (points.isEmpty()) return points
            var minX = Float.MAX_VALUE
            var minY = Float.MAX_VALUE
            var maxX = -Float.MAX_VALUE
            var maxY = -Float.MAX_VALUE
            var i = 0
            while (i < points.size) {
                val x = points[i]
                val y = points[i + 1]
                if (x < minX) minX = x
                if (y < minY) minY = y
                if (x > maxX) maxX = x
                if (y > maxY) maxY = y
                i += 2
            }
            val width = maxX - minX
            val height = maxY - minY
            val scale = maxOf(width, height, 0.0001f)
            val cx = (width / 2f + minX) / scale
            val cy = (height / 2f + minY) / scale
            val out = FloatArray(points.size)
            i = 0
            while (i < points.size) {
                out[i] = points[i] / scale - cx
                out[i + 1] = points[i + 1] / scale - cy
                i += 2
            }
            return out
        }
    }
}
