package com.vocahq.vocaphone.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.VibratorManager
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationTone
import kotlinx.coroutines.delay
import java.io.DataInputStream
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Plays the shipped start/stop WAV for a tone. Off has no file and is silent.
 * Haptics are separate: they fire even when the tone is Off.
 *
 * Every cue is decoded once into a SoundPool when the container is built, so
 * playing one later is a single call with no codec to spin up. That matters
 * because the opening cue sits in front of the microphone on every dictation:
 * a MediaPlayer per play cost around 80 ms of NuPlayer and codec setup on top
 * of the tone itself.
 */
class DictationTonePlayer(context: Context) {
    private val appContext = context.applicationContext

    // USAGE_ASSISTANT, not USAGE_ASSISTANCE_SONIFICATION. Sonification is
    // routed to STREAM_SYSTEM, which most phones alias to the ringer, so every
    // cue was decoded, handed to AudioFlinger and then muted the moment the
    // phone sat in vibrate mode or the system-volume index was 0 -- silent
    // preview button, silent dictation, nothing in the log. A cue that answers
    // a deliberate tap belongs on the volume the user actually keeps up, and
    // anyone who wants silence picks the Off tone.
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private val pool = SoundPool.Builder()
        .setMaxStreams(MAX_STREAMS)
        .setAudioAttributes(attributes)
        .build()

    /** Raw resource to the SoundPool sample cut from it. */
    private val samples = HashMap<Int, Int>(CUES.size)

    /** Raw resource to how long it sounds for, read from the WAV header. */
    private val lengths = HashMap<Int, Long>(CUES.size)

    /** Samples SoundPool has finished decoding. Playing one before it lands is silent. */
    private val ready = ConcurrentHashMap.newKeySet<Int>()

    init {
        pool.setOnLoadCompleteListener { _, sampleId, status ->
            if (status == 0) ready.add(sampleId)
        }
        for (resId in CUES) {
            lengths[resId] = wavDurationMillis(resId)
            samples[resId] = pool.load(appContext, resId, 1)
        }
    }

    fun haptic() {
        val vibrator = appContext.getSystemService(VibratorManager::class.java)?.defaultVibrator
        if (vibrator == null || !vibrator.hasVibrator()) return
        vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
    }

    /**
     * Sounds the opening cue and returns the [SystemClock.elapsedRealtime] mark
     * at which the speaker falls quiet again.
     *
     * The caller gets the mark instead of a suspend that blocks until it passes,
     * so the microphone can open while the cue is still sounding and drop the
     * frames that overlap it. Waiting first put the cue's whole length in front
     * of every dictation -- 600 ms of it for Lift.
     */
    fun startCue(tone: DictationTone): Long = sound(tone.startRes())

    /** Sounds the closing cue. Returns the mark it finishes on, as [startCue] does. */
    fun stopCue(tone: DictationTone): Long = sound(tone.stopRes())

    /** Start cue, then stop cue. Off stays silent. */
    suspend fun preview(tone: DictationTone) {
        val quietAt = startCue(tone)
        delay((quietAt - SystemClock.elapsedRealtime()).coerceAtLeast(0L))
        stopCue(tone)
    }

    /**
     * Returns now for anything that did not sound -- Off, a sample still
     * decoding, a pool that refused the stream -- so a caller waiting on the
     * cue never waits for silence.
     */
    private fun sound(resId: Int?): Long {
        val now = SystemClock.elapsedRealtime()
        if (resId == null) return now
        val sampleId = samples[resId] ?: return now
        if (!ready.contains(sampleId)) return now
        if (pool.play(sampleId, 1f, 1f, 1, 0, 1f) == 0) return now
        return now + (lengths[resId] ?: 0L)
    }

    /**
     * Milliseconds of audio in a RIFF/PCM resource, from its header. The cues
     * are generated assets, so their length is read off the file rather than
     * kept in a table here that would go stale the first time one is re-cut.
     * An unreadable header reports 0, which costs a dropped wait, not a crash.
     */
    private fun wavDurationMillis(resId: Int): Long = try {
        appContext.resources.openRawResource(resId).use { readWavDurationMillis(it) }
    } catch (_: Throwable) {
        0L
    }

    private companion object {
        /** Preview plays one cue at a time; dictation's two are a sentence apart. */
        const val MAX_STREAMS = 2

        val CUES: List<Int> = DictationTone.entries
            .flatMap { listOf(it.startRes(), it.stopRes()) }
            .filterNotNull()
    }
}

/**
 * Milliseconds of PCM in a RIFF stream, or 0 when the header cannot be read.
 * Internal so a test can hold it to the lengths of the cues actually shipped:
 * a silent 0 here would put the opening chime back into the transcript with
 * nothing to show for it.
 */
internal fun readWavDurationMillis(stream: InputStream): Long = try {
    parseWav(DataInputStream(stream))
} catch (_: Throwable) {
    // A short or malformed file runs off the end of a readFully. That is a
    // length we do not know, not a reason to fail a dictation.
    0L
}

private fun parseWav(input: DataInputStream): Long {
    val riff = ByteArray(12)
    input.readFully(riff)
    if (String(riff, 0, 4, Charsets.US_ASCII) != "RIFF") return 0L

    var channels = 0
    var sampleRate = 0
    var bitsPerSample = 0
    var dataBytes = 0L
    val header = ByteArray(8)
    while (true) {
        try {
            input.readFully(header)
        } catch (_: Throwable) {
            break
        }
        val id = String(header, 0, 4, Charsets.US_ASCII)
        val size = littleEndianInt(header, 4)
        if (size < 0) break
        when (id) {
            "fmt " -> {
                val fmt = ByteArray(size)
                input.readFully(fmt)
                if (size < 16) return 0L
                channels = littleEndianShort(fmt, 2)
                sampleRate = littleEndianInt(fmt, 4)
                bitsPerSample = littleEndianShort(fmt, 14)
            }
            "data" -> {
                dataBytes = size.toLong()
            }
            // Chunks are word aligned, so an odd size carries a pad byte.
            else -> input.skipFully(size + (size and 1))
        }
        if (dataBytes > 0L) break
    }

    val bytesPerFrame = channels * (bitsPerSample / 8)
    if (bytesPerFrame <= 0 || sampleRate <= 0) return 0L
    return dataBytes * 1000L / (bytesPerFrame.toLong() * sampleRate.toLong())
}

/** [InputStream.skip] is allowed to skip short, so keep asking until it does not. */
private fun DataInputStream.skipFully(count: Int) {
    var left = count.toLong()
    while (left > 0) {
        val skipped = skip(left)
        if (skipped <= 0) {
            if (read() < 0) return
            left--
        } else {
            left -= skipped
        }
    }
}

private fun littleEndianShort(bytes: ByteArray, offset: Int): Int =
    (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)

private fun littleEndianInt(bytes: ByteArray, offset: Int): Int =
    (bytes[offset].toInt() and 0xFF) or
        ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
        ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
        ((bytes[offset + 3].toInt() and 0xFF) shl 24)

private fun DictationTone.startRes(): Int? = when (this) {
    DictationTone.LIFT -> R.raw.dictation_tone_lift_start
    DictationTone.FLICK -> R.raw.dictation_tone_flick_start
    DictationTone.EMBER -> R.raw.dictation_tone_ember_start
    DictationTone.STEP -> R.raw.dictation_tone_step_start
    DictationTone.VOCA -> R.raw.dictation_tone_voca_start
    DictationTone.SOFT -> R.raw.dictation_tone_soft_start
    DictationTone.CHIRP -> R.raw.dictation_tone_chirp_start
    DictationTone.SCALE -> R.raw.dictation_tone_scale_start
    DictationTone.DROP -> R.raw.dictation_tone_drop_start
    DictationTone.GLASS -> R.raw.dictation_tone_glass_start
    DictationTone.OFF -> null
}

private fun DictationTone.stopRes(): Int? = when (this) {
    DictationTone.LIFT -> R.raw.dictation_tone_lift_stop
    DictationTone.FLICK -> R.raw.dictation_tone_flick_stop
    DictationTone.EMBER -> R.raw.dictation_tone_ember_stop
    DictationTone.STEP -> R.raw.dictation_tone_step_stop
    DictationTone.VOCA -> R.raw.dictation_tone_voca_stop
    DictationTone.SOFT -> R.raw.dictation_tone_soft_stop
    DictationTone.CHIRP -> R.raw.dictation_tone_chirp_stop
    DictationTone.SCALE -> R.raw.dictation_tone_scale_stop
    DictationTone.DROP -> R.raw.dictation_tone_drop_stop
    DictationTone.GLASS -> R.raw.dictation_tone_glass_stop
    DictationTone.OFF -> null
}
