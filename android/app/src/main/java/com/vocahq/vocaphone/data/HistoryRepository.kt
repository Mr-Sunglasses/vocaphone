package com.vocahq.vocaphone.data

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext

/**
 * History plus the bounded audio-retention rule: audio survives only for a
 * failed, still-retryable attempt, and only until its expiry.
 */
class HistoryRepository(private val dao: DictationRecordDao) {

    fun observeRecent(): Flow<List<DictationRecordEntity>> = dao.observeRecent()

    suspend fun find(sessionId: String): DictationRecordEntity? = dao.find(sessionId)

    suspend fun recordSuccess(
        sessionId: String,
        language: String,
        style: String,
        transcript: String,
        targetPackage: String?,
        insertedIntoField: Boolean,
        now: Long = System.currentTimeMillis(),
    ) {
        val existing = dao.find(sessionId)
        // A dictation that succeeded has no reason to keep the recording.
        existing?.audioPath?.let { deleteFile(it) }
        dao.upsert(
            DictationRecordEntity(
                sessionId = sessionId,
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
                language = language,
                style = style,
                state = RECORD_STATE_COMPLETED,
                transcript = transcript,
                targetPackage = targetPackage ?: existing?.targetPackage,
                insertedIntoField = insertedIntoField,
            )
        )
    }

    suspend fun recordFailure(
        sessionId: String,
        language: String,
        style: String,
        errorCode: String,
        errorMessage: String,
        recoverable: Boolean,
        audioFile: File?,
        retentionHours: Int,
        targetPackage: String?,
        now: Long = System.currentTimeMillis(),
    ) {
        val existing = dao.find(sessionId)
        // Audio is only worth keeping for an attempt the user can actually retry.
        val retained = audioFile?.takeIf { recoverable && it.exists() }
        if (retained == null && audioFile != null) deleteFile(audioFile.path)

        dao.upsert(
            DictationRecordEntity(
                sessionId = sessionId,
                createdAt = existing?.createdAt ?: now,
                updatedAt = now,
                language = language,
                style = style,
                state = RECORD_STATE_FAILED,
                errorCode = errorCode,
                errorMessage = errorMessage,
                recoverable = recoverable,
                audioPath = retained?.path,
                audioExpiresAt = retained?.let { now + retentionHours * 3_600_000L },
                targetPackage = targetPackage ?: existing?.targetPackage,
            )
        )
    }

    suspend fun delete(sessionId: String) {
        dao.find(sessionId)?.audioPath?.let { deleteFile(it) }
        dao.delete(sessionId)
    }

    suspend fun deleteAll() {
        dao.withAudio().forEach { record -> record.audioPath?.let { deleteFile(it) } }
        dao.deleteAll()
    }

    /** Drops audio past its retention window and any file left by a crash. */
    suspend fun purgeExpiredAudio(
        audioDirectory: File,
        now: Long = System.currentTimeMillis(),
    ) = withContext(Dispatchers.IO) {
        val expired = dao.expiredAudio(now)
        expired.forEach { record ->
            record.audioPath?.let { deleteFile(it) }
            dao.clearAudio(record.sessionId)
        }
        // Anything on disk that no record points at was left by a process that
        // died mid-dictation. The age check keeps this from racing a recording
        // that is being written right now.
        val referenced = dao.withAudio().mapNotNull { it.audioPath }.toSet()
        audioDirectory.listFiles()?.forEach { file ->
            val orphaned = file.path !in referenced &&
                now - file.lastModified() > ORPHAN_GRACE_MILLIS
            if (orphaned) file.delete()
        }
    }

    private fun deleteFile(path: String) {
        runCatching { File(path).delete() }
    }

    private companion object {
        const val ORPHAN_GRACE_MILLIS = 60 * 60 * 1000L
    }
}
