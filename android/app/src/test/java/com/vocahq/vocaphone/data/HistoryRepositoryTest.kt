package com.vocahq.vocaphone.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryRepositoryTest {

    private class MemoryDao : DictationRecordDao {
        val records = linkedMapOf<String, DictationRecordEntity>()
        override fun observeRecent(limit: Int): Flow<List<DictationRecordEntity>> = emptyFlow()
        override suspend fun find(sessionId: String) = records[sessionId]
        override suspend fun upsert(record: DictationRecordEntity) {
            records[record.sessionId] = record
        }
        override suspend fun delete(sessionId: String) {
            records.remove(sessionId)
        }
        override suspend fun deleteAll() = records.clear()
        override suspend fun expiredAudio(now: Long) =
            records.values.filter { it.audioPath != null && (it.audioExpiresAt ?: 0) <= now }
        override suspend fun withAudio() = records.values.filter { it.audioPath != null }
        override suspend fun clearAudio(sessionId: String) {
            records[sessionId]?.let { records[sessionId] = it.copy(audioPath = null, audioExpiresAt = null) }
        }
        // Mirrors the SQL: changes a matching row in place, never inserts one.
        override suspend fun markInserted(sessionId: String, targetPackage: String?, now: Long, state: String) {
            val existing = records[sessionId]?.takeIf { it.state == state } ?: return
            records[sessionId] = existing.copy(
                insertedIntoField = true,
                targetPackage = targetPackage ?: existing.targetPackage,
                updatedAt = now,
            )
        }
    }

    @Test
    fun `an explicit insert of a saved transcript is recorded with where it went`() = runBlocking {
        val dao = MemoryDao()
        val history = HistoryRepository(dao)
        history.recordSuccess(
            sessionId = "s",
            language = "en",
            style = "clean",
            transcript = "hello",
            targetPackage = "com.example.notes",
            insertedIntoField = false,
            now = 1,
        )

        history.recordInserted("s", targetPackage = "com.example.chat", now = 2)

        val record = dao.records.getValue("s")
        assertTrue(record.insertedIntoField)
        assertEquals("com.example.chat", record.targetPackage)
        assertEquals(2L, record.updatedAt)
        assertEquals("hello", record.transcript)
    }

    @Test
    fun `an insert does not resurrect a deleted record or mark a failure inserted`() = runBlocking {
        val dao = MemoryDao()
        val history = HistoryRepository(dao)

        history.recordInserted("gone", targetPackage = "com.example.chat")
        assertNull(dao.records["gone"])

        history.recordFailure(
            sessionId = "failed",
            language = "en",
            style = "clean",
            errorCode = "network",
            errorMessage = "offline",
            recoverable = false,
            audioFile = null,
            retentionHours = 6,
            targetPackage = null,
        )
        history.recordInserted("failed", targetPackage = "com.example.chat")
        assertFalse(dao.records.getValue("failed").insertedIntoField)
    }

    @Test
    fun `the transcript without Fix grammar is kept only when the model changed it`() = runBlocking {
        val dao = MemoryDao()
        val history = HistoryRepository(dao)
        history.recordSuccess("a", "en", "clean", "He doesn't know.", null, false, transcriptWithoutGrammar = "He don't know.")
        history.recordSuccess("b", "en", "clean", "Fine.", null, false, transcriptWithoutGrammar = "Fine.")

        assertEquals("He don't know.", dao.records.getValue("a").transcriptWithoutGrammar)
        assertNull(dao.records.getValue("b").transcriptWithoutGrammar)
    }
}
