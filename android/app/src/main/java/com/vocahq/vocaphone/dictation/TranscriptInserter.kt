package com.vocahq.vocaphone.dictation

/** What was written into a field, and where, so Undo can check it is still there. */
data class AppliedInsertion(
    val packageName: String?,
    val insertionStart: Int,
    val inserted: String,
)

enum class InsertionOutcome {
    /** The transcript is in the field and the cursor is after it. */
    INSERTED,

    /** No safe editable target: the transcript stays in history for the user. */
    NO_TARGET,

    /** A custom editor that does not implement the text actions. */
    UNSUPPORTED_EDITOR,
}

data class InsertionReport(
    val outcome: InsertionOutcome,
    val applied: AppliedInsertion? = null,
)

/**
 * Implemented by the accessibility service. Kept as an interface so the
 * dictation pipeline can be exercised without one running.
 */
interface TranscriptInserter {
    suspend fun insert(transcript: String): InsertionReport
    suspend fun undo(insertion: AppliedInsertion): Boolean
    fun currentTargetPackage(): String?
}
