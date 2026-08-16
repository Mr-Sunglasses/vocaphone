package com.vocahq.vocaphone.settings

import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

internal object ClipboardImages {
    const val DIR = "clipboard"
    const val MAX_BYTES = 8 * 1024 * 1024

    fun cache(context: Context, uri: Uri, mime: String): String? {
        val dir = File(context.filesDir, DIR).apply { mkdirs() }
        val dest = File(dir, "${System.currentTimeMillis()}.${extension(mime)}")
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output ->
                    val buffer = ByteArray(16 * 1024)
                    var written = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        written += read
                        if (written > MAX_BYTES) {
                            dest.delete()
                            return null
                        }
                        output.write(buffer, 0, read)
                    }
                }
            } ?: return null
            if (dest.length() == 0L) {
                dest.delete()
                return null
            }
            "$DIR/${dest.name}"
        } catch (_: Exception) {
            dest.delete()
            null
        }
    }

    fun file(context: Context, relativePath: String): File = File(context.filesDir, relativePath)

    fun contentUri(context: Context, relativePath: String): Uri =
        FileProvider.getUriForFile(
            context,
            "${context.packageName}.clipboard",
            file(context, relativePath),
        )

    fun prune(context: Context, keepRelative: Set<String>) {
        val dir = File(context.filesDir, DIR)
        if (!dir.isDirectory) return
        val keep = keepRelative.map { it.substringAfterLast('/') }.toSet()
        dir.listFiles()?.forEach { file ->
            if (file.name !in keep) file.delete()
        }
    }

    private fun extension(mime: String): String = when {
        mime.contains("png") -> "png"
        mime.contains("webp") -> "webp"
        mime.contains("gif") -> "gif"
        mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
        else -> "img"
    }
}
