package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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

    ;

    val handle: String?
        get() = if (this == X) "@vocahq" else null
}

internal object StatsShareComposer {
    private const val SITE = "https://vocaphone.vocahq.com"

    fun message(stats: UsageStats, nowMillis: Long, destination: StatsShareDestination): String {
        val streak = stats.currentStreakAt(nowMillis)
        val details = buildList {
            if (stats.totalTranscriptions > 0) {
                add("📊 ${pluralized(stats.totalTranscriptions, "session")}")
            }
            spokenDuration(stats.totalAudioMillis)?.let { add("⏱️ $it of talking") }
            if (stats.averageWordsPerMinute > 0) {
                add("⚡️ ${String.format(Locale.US, "%.0f", stats.averageWordsPerMinute)} WPM")
            }
            if (streak > 0) add("🔥 $streak-day streak")
        }
        return listOf(
            "🎤 I’ve spoken ${pluralized(stats.totalWords, "word")} with VocaPhone.",
            details.joinToString(" · "),
            "Private voice typing on my phone or my own self-hosted gateway. My audio stays mine. 🔒",
            listOfNotNull(destination.handle, SITE).joinToString(" · "),
        ).filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    fun pluralized(count: Long, noun: String): String =
        "${StatsFormat.count(count, Locale.US)} ${if (count == 1L) noun else "${noun}s"}"

    fun spokenDuration(millis: Long): String? {
        val totalMinutes = millis.coerceAtLeast(0) / 60_000
        if (totalMinutes == 0L) return null
        val hours = totalMinutes / 60
        val minutes = totalMinutes % 60
        return buildList {
            if (hours > 0) add("$hours ${if (hours == 1L) "hour" else "hours"}")
            if (minutes > 0) add("$minutes ${if (minutes == 1L) "minute" else "minutes"}")
        }.joinToString(", ")
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
    enum class ShareTarget { INSTALLED_APP, BROWSER }

    data class ShareResult(
        val opened: Boolean,
        val cardCopied: Boolean,
        val textCopied: Boolean,
        val target: ShareTarget?,
    )

    private data class PayloadResult(val cardCopied: Boolean, val textCopied: Boolean)
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
        val message = StatsShareComposer.message(stats, nowMillis, destination)
        val cardUri = createCardUri(context, stats, nowMillis)
        val payload = copySharePayload(context, cardUri, message)
        if (openInstalledApp(context, destination, message, cardUri)) {
            return ShareResult(true, payload.cardCopied, payload.textCopied, ShareTarget.INSTALLED_APP)
        }

        // Do not call resolveActivity first. On modern Android, package
        // visibility can hide an otherwise valid browser from that query; the
        // implicit VIEW intent is still allowed to resolve when launched.
        val webIntent = Intent(
            Intent.ACTION_VIEW,
            StatsShareComposer.composerUri(destination, message),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val opened = runCatching { context.startActivity(webIntent) }.isSuccess
        return ShareResult(
            opened = opened,
            cardCopied = payload.cardCopied,
            textCopied = payload.textCopied,
            target = if (opened) ShareTarget.BROWSER else null,
        )
    }

    /**
     * Installed apps get several native opportunities before the browser.
     * Some releases reject a PNG share but still accept text or their own web
     * composer. The final launch intent still opens the installed app with the
     * card and post text waiting on the clipboard.
     */
    private fun openInstalledApp(
        context: Context,
        destination: StatsShareDestination,
        message: String,
        cardUri: Uri?,
    ): Boolean {
        if (!isPackageInstalled(context.packageManager, destination.packageName)) return false
        val intents = buildList {
            if (cardUri != null) add(nativeShareIntent(context, destination, message, cardUri))
            add(nativeTextShareIntent(destination, message))
            add(
                Intent(Intent.ACTION_VIEW, StatsShareComposer.composerUri(destination, message))
                    .setPackage(destination.packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            context.packageManager.getLaunchIntentForPackage(destination.packageName)?.let {
                add(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
        return intents.any { intent -> runCatching { context.startActivity(intent) }.isSuccess }
    }

    private fun isPackageInstalled(packageManager: PackageManager, packageName: String): Boolean =
        runCatching {
            packageManager.getApplicationInfo(
                packageName,
                PackageManager.ApplicationInfoFlags.of(0),
            ).enabled
        }.getOrDefault(false)

    private fun copySharePayload(context: Context, uri: Uri?, message: String): PayloadResult {
        val clip = if (uri == null) {
            ClipData.newPlainText("VocaPhone stats", message)
        } else {
            ClipData.newUri(context.contentResolver, "VocaPhone stats", uri).also {
                it.addItem(ClipData.Item(message))
            }
        }
        val copied = runCatching {
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        }.isSuccess
        return PayloadResult(cardCopied = copied && uri != null, textCopied = copied)
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

    private fun nativeTextShareIntent(
        destination: StatsShareDestination,
        message: String,
    ): Intent =
        Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            setPackage(destination.packageName)
            putExtra(Intent.EXTRA_TEXT, message)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
        text("PRIVATE • YOUR CHOICE", 796f, 96f, 18f, green, true)
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
        text("Your voice. Your control.", 770f, 660f, 20f, green)
        return bitmap
    }
}
