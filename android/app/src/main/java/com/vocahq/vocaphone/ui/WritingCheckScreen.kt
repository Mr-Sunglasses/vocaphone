package com.vocahq.vocaphone.ui

import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.ime.PersonalDictionary
import com.vocahq.vocaphone.ime.WritingColors
import com.vocahq.vocaphone.local.GrammarModelCatalog
import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingSuggestion
import com.vocahq.vocaphone.writing.writingCategories
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Grammarly's editor, on this phone: write or paste, and every suggestion is
 * underlined in its group's colour, with a card for each (Accept, Ignore,
 * Add to dictionary), a score, readability and how the text sounds.
 * [onReplace] is set when the text came from another app's field and can go
 * back into it. Mirrors `ios/VocaPhoneApp/App/WritingCheckView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WritingCheckScreen(
    initialText: String,
    onReplace: ((String) -> Unit)?,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val container = remember { VocaPhoneApplication.container(context) }
    val scope = rememberCoroutineScope()
    // Saved, so rotating the phone keeps what the user wrote and accepted
    // rather than going back to the text the screen was opened on.
    var value by rememberSaveable(stateSaver = TextFieldValue.Saver) {
        mutableStateOf(TextFieldValue(initialText, TextRange(initialText.length)))
    }
    var report by remember { mutableStateOf<WritingCheck.Report?>(null) }
    var checking by remember { mutableStateOf(false) }
    var filter by rememberSaveable { mutableStateOf<WritingCategory?>(null) }
    var dismissed by rememberSaveable { mutableStateOf(setOf<String>()) }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val text = value.text

    LaunchedEffect(text) {
        delay(CHECK_PAUSE_MILLIS)
        if (text.isBlank()) {
            report = null
            return@LaunchedEffect
        }
        checking = true
        try {
            val result = withContext(Dispatchers.Default) { check(container, text) }
            if (result?.text == value.text) report = result
        } finally {
            checking = false
        }
    }

    val visible = report?.takeIf { it.text == text }?.suggestions.orEmpty().filter { it.key !in dismissed }
    val shown = visible.filter { filter == null || it.category == filter }

    fun accept(chosen: List<WritingSuggestion>) {
        // Only a report on the text as it is: its offsets are into that text.
        val current = report?.takeIf { it.text == value.text } ?: return
        var edited = value.text
        var remaining = current.suggestions
        for (s in chosen.sortedByDescending { it.start }) {
            val next = WritingCheck.apply(edited, s) ?: continue
            remaining = WritingCheck.rebase(remaining.filter { it != s }, edited, next)
            edited = next
        }
        report = current.copy(text = edited, suggestions = remaining)
        value = TextFieldValue(edited, TextRange(edited.length))
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Writing check") },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(painterResource(R.drawable.ic_cancel), contentDescription = "Close")
                    }
                },
                actions = {
                    IconButton(onClick = {
                        context.getSystemService(ClipboardManager::class.java)?.primaryClip
                            ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
                            ?.let { value = TextFieldValue(it, TextRange(it.length)) }
                    }) {
                        Icon(painterResource(R.drawable.ic_clipboard), contentDescription = "Paste")
                    }
                    IconButton(onClick = { context.copyToClipboard(text) }, enabled = text.isNotEmpty()) {
                        Icon(painterResource(R.drawable.ic_copy), contentDescription = "Copy")
                    }
                    IconButton(onClick = { context.shareText(text) }, enabled = text.isNotEmpty()) {
                        Icon(painterResource(R.drawable.ic_share), contentDescription = "Share")
                    }
                    if (onReplace != null) {
                        TextButton(onClick = { onReplace(text) }) { Text("Replace") }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Box(Modifier.padding(16.dp).heightIn(min = 160.dp)) {
                    if (text.isEmpty()) {
                        Text(
                            "Paste or write something. It is checked on this phone and never sent anywhere.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                    val marks = visible
                    val colors = marks.associate { it to WritingColors.of(it.category) }
                    BasicTextField(
                        value = value,
                        onValueChange = { value = it },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        onTextLayout = { layout = it },
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = "Text to check" }
                            .drawBehind {
                                // Grammarly's underlines, in each group's colour.
                                val l = layout ?: return@drawBehind
                                if (l.layoutInput.text.text != text) return@drawBehind
                                for (s in marks) {
                                    val end = minOf(s.markEnd, text.length)
                                    if (s.markStart >= end) continue
                                    val first = l.getLineForOffset(s.markStart)
                                    val last = l.getLineForOffset(end - 1)
                                    for (line in first..last) {
                                        val from = maxOf(s.markStart, l.getLineStart(line))
                                        val to = minOf(end, l.getLineEnd(line))
                                        if (to <= from) continue
                                        val y = l.getLineBottom(line) - 1.dp.toPx()
                                        drawLine(
                                            color = colors.getValue(s),
                                            start = Offset(l.getHorizontalPosition(from, true), y),
                                            end = Offset(l.getHorizontalPosition(to, true), y),
                                            strokeWidth = 2.dp.toPx(),
                                        )
                                    }
                                }
                            },
                    )
                }
            }
            report?.takeIf { it.text == text && text.isNotBlank() }?.let { Summary(it, checking) }
            if (visible.isNotEmpty()) {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(selected = filter == null, onClick = { filter = null }, label = { Text("All ${visible.size}") })
                    WritingCategory.entries.forEach { category ->
                        val count = visible.count { it.category == category }
                        if (count > 0) {
                            FilterChip(
                                selected = filter == category,
                                onClick = { filter = category },
                                label = { Text("${WritingColors.name(category)} $count") },
                                leadingIcon = {
                                    Box(Modifier.size(8.dp).clip(CircleShape).background(WritingColors.of(category)))
                                },
                            )
                        }
                    }
                }
                val mechanical = shown.filter { it.isActionable && it.mechanical }
                if (mechanical.size >= 2) {
                    TextButton(onClick = { accept(mechanical) }) { Text("Accept all ${mechanical.size} spelling and punctuation fixes") }
                }
            }
            shown.forEach { s ->
                SuggestionCard(
                    s,
                    onAccept = { accept(listOf(s)) },
                    onIgnore = { dismissed = dismissed + s.key },
                    onAddWord = {
                        scope.launch { container.settings.addPersonalWord(s.shownOriginal) }
                        dismissed = dismissed + s.key
                    },
                )
            }
            if (report != null && text.isNotBlank() && visible.isEmpty() && !checking) {
                Text("No issues found.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.heightIn(min = 24.dp))
        }
    }
}

private const val CHECK_PAUSE_MILLIS = 450L

/** The rules, the grammar model when it is downloaded, and the user's settings. */
private suspend fun check(container: com.vocahq.vocaphone.AppContainer, text: String): WritingCheck.Report? {
    val checker = container.writingCheck ?: return null
    val settings = container.settings.current()
    val keep = DictatedTranscript.grammarKeeps(
        PersonalDictionary.terms(settings.personalDictionary) + CustomVocabulary.terms(settings.customVocabulary),
        settings.snippets,
    )
    val model = if (GrammarModelCatalog.available && container.grammarModel.isReady()) {
        WritingCheck.Model { container.grammar.correctTyped(it, keep) }
    } else {
        null
    }
    val options = WritingCheck.Options(settings.writingCategories(), keep, typed = true)
    var report = checker.check(text, model, options)
    if (report.modelPending) {
        // The model was loading; asking started it. Once more, a moment later.
        delay(1_200)
        report = checker.check(text, model, options)
    }
    return if (settings.writingTone) report else report.copy(tones = emptyList())
}

@Composable
private fun Summary(report: WritingCheck.Report, checking: Boolean) {
    val stats = report.stats
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(56.dp)) {
            CircularProgressIndicator(
                progress = { (stats.score ?: 0) / 100f },
                modifier = Modifier.size(56.dp),
                strokeWidth = 5.dp,
                trackColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            )
            Text(stats.score?.toString() ?: "–", style = MaterialTheme.typography.titleMedium)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            val minutes = if (stats.readingSeconds < 60) "${maxOf(stats.readingSeconds, 1)} s" else "${(stats.readingSeconds + 59) / 60} min"
            Text("${stats.words} words · $minutes to read", style = MaterialTheme.typography.titleSmall)
            stats.readabilityLabel?.let {
                Text("Readability ${stats.readability} · $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (report.tones.isNotEmpty()) {
                Text(
                    "Sounds " + report.tones.joinToString(" · ") { "${it.emoji} ${it.label}" },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (checking) Text("Checking…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SuggestionCard(
    s: WritingSuggestion,
    onAccept: () -> Unit,
    onIgnore: () -> Unit,
    onAddWord: () -> Unit,
) {
    val color = WritingColors.of(s.category)
    Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                Spacer(Modifier.width(8.dp))
                Text(
                    "${WritingColors.name(s.category)} · ${s.title}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            s.shownReplacement?.let { replacement ->
                Text(
                    buildAnnotatedString {
                        if (s.shownOriginal.isNotEmpty()) {
                            withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough, color = MaterialTheme.colorScheme.onSurfaceVariant)) {
                                append(s.shownOriginal)
                            }
                            append("  ")
                        }
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = color)) {
                            append(replacement.ifEmpty { "(remove)" })
                        }
                    },
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            Text(s.message, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 4.dp, end = 8.dp))
            Row {
                if (s.isActionable) TextButton(onClick = onAccept) { Text("Accept") }
                TextButton(onClick = onIgnore) { Text("Ignore") }
                if (s.kind == "spelling" && s.shownOriginal.none(Char::isWhitespace)) {
                    TextButton(onClick = onAddWord) { Text("Add to dictionary") }
                }
            }
        }
    }
}
