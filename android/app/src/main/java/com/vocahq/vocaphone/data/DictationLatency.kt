package com.vocahq.vocaphone.data

/**
 * Median and p95 of the dictation spans that [DiagnosticLog] already stamps.
 *
 * The log records when each stage happened; nothing turned that into the
 * number a latency budget is written in. This reads the log back, pairs each
 * span's start with the first matching end inside the same dictation, and
 * reports how long they took. See docs/latency.md for the budgets.
 *
 * Input and output are both the log's closed vocabulary plus integers, so the
 * summary is as safe to paste publicly as the log it came from.
 */
object DictationLatency {

    data class Span(val label: String, val from: String, val to: String)

    data class Summary(val label: String, val count: Int, val medianMillis: Long, val p95Millis: Long)

    /**
     * Tap → listening includes the start cue on purpose: LISTENING is the
     * "speak now" state, and the cue is part of what the user waits through.
     */
    val SPANS = listOf(
        Span("Tap -> listening", from = "action:start", to = "state:LISTENING"),
        Span("Stop -> mic off", from = "timing:finish_requested", to = "timing:capture_stopped"),
        Span("Stop -> transcript", from = "timing:finish_requested", to = "timing:transcript_ready"),
        Span("Stop -> inserted", from = "timing:finish_requested", to = "timing:insertion_completed"),
    )

    /**
     * Events that end a dictation, so a span never pairs across two of them.
     *
     * Not IDLE: states are logged by a collector, so the IDLE from clearing the
     * last result can be written after the synchronous "start" that follows it.
     */
    private val BOUNDARIES = setOf("action:start", "action:cancel", "state:FAILED")

    fun summarize(events: String, spans: List<Span> = SPANS): List<Summary> {
        val samples = spans.associateWith { mutableListOf<Long>() }
        val open = mutableMapOf<Span, Long>()
        for (line in events.lineSequence()) {
            val fields = parse(line) ?: continue
            val ts = fields["ts"]?.toLongOrNull() ?: continue
            val key = "${fields["event"]}:${fields["value"]}"
            for (span in spans) {
                val startedAt = open[span]
                if (key == span.to && startedAt != null) {
                    samples.getValue(span) += (ts - startedAt).coerceAtLeast(0L)
                    open.remove(span)
                }
            }
            if (key in BOUNDARIES) open.clear()
            // A second Finish tap is not a new request; the first is the tap.
            for (span in spans) {
                if (key == span.from && span !in open) open[span] = ts
            }
        }
        return spans.mapNotNull { span ->
            val values = samples.getValue(span).sorted()
            if (values.isEmpty()) {
                null
            } else {
                Summary(span.label, values.size, percentile(values, 50), percentile(values, 95))
            }
        }
    }

    fun reportLines(events: String): List<String> = summarize(events).map {
        "${it.label}: ${it.medianMillis} ms median, ${it.p95Millis} ms p95 (n=${it.count})"
    }

    /** Nearest-rank, so every reported value is one that was actually measured. */
    internal fun percentile(sorted: List<Long>, percent: Int): Long {
        val rank = (percent / 100.0 * sorted.size).let { kotlin.math.ceil(it).toInt() }
        return sorted[(rank - 1).coerceIn(0, sorted.lastIndex)]
    }

    private fun parse(line: String): Map<String, String>? {
        if (line.isBlank()) return null
        return line.trim().split(' ').mapNotNull { field ->
            val separator = field.indexOf('=')
            if (separator <= 0) null else field.substring(0, separator) to field.substring(separator + 1)
        }.toMap()
    }
}
