package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import androidx.core.content.FileProvider
import com.vocahq.vocaphone.core.UsageStats
import com.vocahq.vocaphone.settings.ClipboardImages
import java.io.File
import java.util.Locale

internal enum class StatsShareDestination(val label: String, val packageName: String) {
    X("X", "com.twitter.android"),
    LINKEDIN("LinkedIn", "com.linkedin.android"),
}

internal object StatsShareComposer {
    private const val SITE = "https://vocaphone.vocahq.com"

    fun message(stats: UsageStats, nowMillis: Long): String {
        val streak = stats.currentStreakAt(nowMillis)
        return buildString {
            append("🎤 I’ve dictated ${StatsFormat.count(stats.totalWords)} ")
            append(if (stats.totalWords == 1L) "word" else "words")
            append(" with VocaPhone.\n\n")
            append("📊 ${StatsFormat.count(stats.totalTranscriptions)} ")
            append(if (stats.totalTranscriptions == 1L) "session" else "sessions")
            if (stats.averageWordsPerMinute > 0) {
                append(" · ⚡ ${String.format(Locale.US, "%.0f", stats.averageWordsPerMinute)} WPM")
            }
            if (streak > 0) append(" · 🔥 $streak-day streak")
            append("\n\nRuns on my phone, privately. 🔒\n$SITE")
        }
    }

    fun composerUri(destination: StatsShareDestination, message: String): Uri {
        val encoded = Uri.encode(message)
        return when (destination) {
            StatsShareDestination.X -> Uri.parse("https://x.com/intent/post?text=$encoded")
            StatsShareDestination.LINKEDIN ->
                Uri.parse("https://www.linkedin.com/feed/?shareActive=true&text=$encoded")
        }
    }
}

internal object StatsShareExporter {
    data class ShareResult(val opened: Boolean, val cardCopied: Boolean)
    private const val WIDTH = 1080
    private const val HEIGHT = 720

    /** Creates the VocaMac-inspired share image and leaves it on Android's clipboard. */
    fun copyCard(context: Context, stats: UsageStats, nowMillis: Long): Boolean {
        val uri = createCardUri(context, stats, nowMillis) ?: return false
        return runCatching {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "VocaPhone stats", uri))
            true
        }.getOrDefault(false)
    }

    fun share(context: Context, stats: UsageStats, nowMillis: Long, destination: StatsShareDestination): ShareResult {
        val message = StatsShareComposer.message(stats, nowMillis)
        val cardUri = createCardUri(context, stats, nowMillis)
        val cardCopied = cardUri?.let { uri ->
            runCatching {
                context.getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newUri(context.contentResolver, "VocaPhone stats", uri))
            }.isSuccess
        } ?: false
        val nativeOpened = cardUri?.let { uri ->
            runCatching {
                context.startActivity(nativeShareIntent(context, destination, message, uri))
            }.isSuccess
        } ?: false
        if (nativeOpened) return ShareResult(true, cardCopied)

        // Do not call resolveActivity first. On modern Android, package
        // visibility can hide an otherwise valid browser from that query; the
        // implicit VIEW intent is still allowed to resolve when launched.
        val webIntent = Intent(
            Intent.ACTION_VIEW,
            StatsShareComposer.composerUri(destination, message),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val opened = runCatching { context.startActivity(webIntent) }.isSuccess
        return ShareResult(opened, cardCopied)
    }

    private fun nativeShareIntent(
        context: Context,
        destination: StatsShareDestination,
        message: String,
        uri: Uri,
    ): Intent =
        Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            setPackage(destination.packageName)
            putExtra(Intent.EXTRA_TEXT, message)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(context.contentResolver, "VocaPhone stats", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }

    private fun createCardUri(context: Context, stats: UsageStats, nowMillis: Long): Uri? {
        val bitmap = renderCard(stats, nowMillis)
        val file = File(context.filesDir, "${ClipboardImages.DIR}/stats-card.png")
        return runCatching {
            file.parentFile?.mkdirs()
            val written = file.outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            check(written)
            FileProvider.getUriForFile(context, "${context.packageName}.clipboard", file)
        }.getOrNull().also { bitmap.recycle() }
    }

    private fun renderCard(stats: UsageStats, nowMillis: Long): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(android.graphics.Color.rgb(25, 29, 28))
        val white = android.graphics.Color.WHITE
        val muted = android.graphics.Color.rgb(180, 193, 188)
        val green = android.graphics.Color.rgb(121, 216, 191)
        val orange = android.graphics.Color.rgb(255, 172, 92)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.create("sans", Typeface.NORMAL) }
        fun text(value: String, x: Float, y: Float, size: Float, color: Int, bold: Boolean = false) {
            paint.textSize = size; paint.color = color
            paint.typeface = Typeface.create("sans", if (bold) Typeface.BOLD else Typeface.NORMAL)
            canvas.drawText(value, x, y, paint)
        }
        fun box(left: Float, top: Float, right: Float, bottom: Float, color: Int) {
            paint.color = color; canvas.drawRoundRect(left, top, right, bottom, 28f, 28f, paint)
        }
        text("VocaPhone", 72f, 92f, 42f, white, true)
        text("My dictation stats", 72f, 132f, 25f, muted)
        text("PRIVATE • ON DEVICE", 820f, 96f, 18f, green, true)
        val values = listOf(
            Triple("WORDS", StatsFormat.count(stats.totalWords), green),
            Triple("SESSIONS", StatsFormat.count(stats.totalTranscriptions), green),
            Triple("TIME", StatsFormat.duration(stats.totalAudioMillis), orange),
            Triple("SPEED", "${StatsFormat.wordsPerMinute(stats.averageWordsPerMinute)} WPM", green),
            Triple("STREAK", StatsFormat.streak(stats.currentStreakAt(nowMillis)), orange),
            Triple("BEST", StatsFormat.streak(stats.bestStreak), orange),
        )
        values.forEachIndexed { index, item ->
            val column = index % 3; val row = index / 3
            val left = 72f + column * 316f; val top = 188f + row * 190f
            box(left, top, left + 286f, top + 150f, android.graphics.Color.rgb(34, 40, 38))
            text(item.first, left + 24f, top + 40f, 18f, muted, true)
            text(item.second, left + 24f, top + 92f, 32f, white, true)
            paint.color = item.third; canvas.drawRoundRect(left + 24f, top + 116f, left + 68f, top + 122f, 4f, 4f, paint)
        }
        text("vocaphone.vocahq.com", 72f, 660f, 20f, muted)
        text("Your voice. Your device.", 780f, 660f, 20f, green)
        return bitmap
    }
}
