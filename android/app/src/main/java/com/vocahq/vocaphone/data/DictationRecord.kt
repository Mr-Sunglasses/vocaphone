package com.vocahq.vocaphone.data

import androidx.room.AutoMigration
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

const val RECORD_STATE_COMPLETED = "completed"
const val RECORD_STATE_FAILED = "failed"

/**
 * One dictation as the user sees it in History. Recorded audio is referenced by
 * [audioPath] only while the attempt is still retryable; a successful dictation
 * never keeps one.
 */
@Entity(tableName = "dictation_records")
data class DictationRecordEntity(
    @PrimaryKey val sessionId: String,
    val createdAt: Long,
    val updatedAt: Long,
    val language: String,
    val style: String,
    val state: String,
    val transcript: String? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val recoverable: Boolean = false,
    val audioPath: String? = null,
    val audioExpiresAt: Long? = null,
    val targetPackage: String? = null,
    val insertedIntoField: Boolean = false,
    /**
     * The transcript as it would have been without Fix grammar, kept only
     * when the grammar model changed something, so History can show what it
     * changed and give the original back.
     */
    val transcriptWithoutGrammar: String? = null,
)

@Dao
interface DictationRecordDao {

    @Query("SELECT * FROM dictation_records ORDER BY createdAt DESC LIMIT :limit")
    fun observeRecent(limit: Int = 200): Flow<List<DictationRecordEntity>>

    @Query("SELECT * FROM dictation_records WHERE sessionId = :sessionId")
    suspend fun find(sessionId: String): DictationRecordEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(record: DictationRecordEntity)

    @Query("DELETE FROM dictation_records WHERE sessionId = :sessionId")
    suspend fun delete(sessionId: String)

    @Query("DELETE FROM dictation_records")
    suspend fun deleteAll()

    @Query("SELECT * FROM dictation_records WHERE audioPath IS NOT NULL AND audioExpiresAt <= :now")
    suspend fun expiredAudio(now: Long): List<DictationRecordEntity>

    @Query("SELECT * FROM dictation_records WHERE audioPath IS NOT NULL")
    suspend fun withAudio(): List<DictationRecordEntity>

    @Query("UPDATE dictation_records SET audioPath = NULL, audioExpiresAt = NULL WHERE sessionId = :sessionId")
    suspend fun clearAudio(sessionId: String)

    /**
     * One statement, so a delete that lands meanwhile cannot be undone by
     * writing the row back. Only a row still in [state] changes.
     */
    @Query(
        "UPDATE dictation_records SET insertedIntoField = 1, " +
            "targetPackage = COALESCE(:targetPackage, targetPackage), updatedAt = :now " +
            "WHERE sessionId = :sessionId AND state = :state"
    )
    suspend fun markInserted(sessionId: String, targetPackage: String?, now: Long, state: String)
}

@Database(
    entities = [DictationRecordEntity::class],
    version = 2,
    exportSchema = true,
    // 2: transcriptWithoutGrammar, a nullable column; old rows read as null.
    autoMigrations = [AutoMigration(from = 1, to = 2)],
)
abstract class VocaPhoneDatabase : RoomDatabase() {
    abstract fun dictationRecordDao(): DictationRecordDao
}
