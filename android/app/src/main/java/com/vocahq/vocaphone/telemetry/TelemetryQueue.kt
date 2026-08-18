package com.vocahq.vocaphone.telemetry

import java.util.ArrayDeque

/**
 * Events waiting for a flush.
 *
 * In-memory and bounded. Because there is no persistent identity behind these
 * events (see [TelemetryConfig]), one that never reaches the server is simply
 * gone — so a disk-backed queue would add storage, code, and privacy surface to
 * protect data that is worth none of it.
 *
 * Overflow drops the **oldest**. A queue that dropped the newest would go deaf
 * exactly when something started going wrong repeatedly, which is the one
 * moment the events matter.
 */
internal class TelemetryQueue(private val capacity: Int = TelemetryConfig.MAX_QUEUE) {

    private val pending = ArrayDeque<TelemetryRecord>()

    @Synchronized
    fun add(record: TelemetryRecord) {
        while (pending.size >= capacity) {
            pending.pollFirst()
        }
        pending.addLast(record)
    }

    @Synchronized
    fun isEmpty(): Boolean = pending.isEmpty()

    @Synchronized
    fun size(): Int = pending.size

    /** A copy, oldest first, for the "See what's sent" screen. */
    @Synchronized
    fun peekAll(): List<TelemetryRecord> = pending.toList()

    /**
     * Removes and returns up to [TelemetryConfig.MAX_BATCH] events, oldest
     * first. Taken rather than peeked because a failed batch is dropped, not
     * retried indefinitely: see [Telemetry.flush].
     */
    @Synchronized
    fun takeBatch(): List<TelemetryRecord> {
        val batch = ArrayList<TelemetryRecord>(minOf(pending.size, TelemetryConfig.MAX_BATCH))
        while (batch.size < TelemetryConfig.MAX_BATCH) {
            batch.add(pending.pollFirst() ?: break)
        }
        return batch
    }

    /** Puts a failed batch back at the front, so ordering survives one retry. */
    @Synchronized
    fun requeue(batch: List<TelemetryRecord>) {
        batch.asReversed().forEach { record ->
            if (pending.size >= capacity) return
            pending.addFirst(record)
        }
    }

    @Synchronized
    fun clear() {
        pending.clear()
    }
}
