package com.vocahq.vocaphone.grammar

import com.vocahq.vocaphone.core.GrammarStage
import com.vocahq.vocaphone.local.GrammarModelCatalog
import com.vocahq.vocaphone.local.GrammarModelStore
import java.io.File
import java.util.concurrent.Executors
import org.json.JSONArray

/** How long the whole stage may take for one transcript. */
internal const val GRAMMAR_BUDGET_MILLIS = 150L

/** How long one check of typed text may take; see [GrammarCorrector.correctTyped]. */
internal const val TYPED_BUDGET_MILLIS = 400L

/**
 * The "Fix grammar (English)" stage: [GrammarTagger] over a [GrammarSession],
 * fed from the verified files in [GrammarModelStore].
 *
 * Built to fail safe, because dictation must never fail or noticeably slow
 * down for an optional nicety. Every way this can go wrong — no model yet, a
 * damaged file, ONNX Runtime refusing to load, running past the budget —
 * returns the transcript as it was and leaves one content-free line in the
 * diagnostic log. Nothing reaches telemetry.
 *
 * Loading costs a few hundred milliseconds (a 1.1 MB tokenizer and a 27 MB
 * session), so it happens off the dictation path: [warm] is called when a
 * recording starts. A transcript that finishes before the load does is left
 * alone rather than waited on.
 */
class GrammarCorrector internal constructor(
    private val store: GrammarModelStore,
    private val log: (String) -> Unit,
    private val budgetMillis: Long = GRAMMAR_BUDGET_MILLIS,
    private val available: () -> Boolean = { GrammarModelCatalog.available },
    private val load: (File) -> Loaded = ::loadFrom,
) : GrammarStage {
    constructor(store: GrammarModelStore, log: (String) -> Unit) : this(store, log, GRAMMAR_BUDGET_MILLIS)

    /** A tagger and whatever has to be closed with it. */
    internal class Loaded(val tagger: GrammarTagger, val close: () -> Unit)

    private val loader = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "grammar-load").apply { isDaemon = true }
    }
    private val lock = Any()
    private var loaded: Loaded? = null
    private var loading = false
    /**
     * Bumped by [release]. A load that started before the release finishes
     * into a session nobody wants any more, so it is closed instead of kept:
     * otherwise a memory-trim release during a warm-up left the session in
     * memory after Android asked for it back.
     */
    private var generation = 0
    /** Set after a load failed for these files, so a broken install is not retried per dictation. */
    private var failedFor: Long? = null

    /**
     * "Only sure fixes": a higher KEEP bias, so only edits the model is surer
     * of get through. Follows the setting; read once per check.
     */
    @Volatile
    var sureOnly: Boolean = false

    /** Starts loading the model in the background, if it is downloaded and not loaded yet. */
    fun warm() {
        if (!available() || !store.isReady()) return
        val started = synchronized(lock) {
            if (loaded != null || loading || failedFor == fingerprint()) return
            loading = true
            generation
        }
        loader.execute {
            val result = runCatching { load(store.modelDirectory) }
            val stale = synchronized(lock) {
                loading = false
                val current = started == generation
                if (current) {
                    result.onSuccess { loaded = it }
                    result.onFailure { failedFor = fingerprint() }
                }
                !current
            }
            when {
                stale -> result.getOrNull()?.close?.invoke()
                result.isFailure -> log("grammar_load_failed")
            }
        }
    }

    override fun correct(text: String, keep: Set<String>): String = run(text, keep, budgetMillis) ?: text

    /**
     * For "Check grammar while typing": [text] corrected, or null when the
     * model is not loaded yet, which starts loading it. Nobody is waiting on
     * an insertion here, so the budget is longer than dictation's; it still
     * bounds a paragraph pasted into the field.
     */
    fun correctTyped(text: String, keep: Set<String>): String? = run(text, keep, TYPED_BUDGET_MILLIS)

    private fun run(text: String, keep: Set<String>, budget: Long): String? {
        val current = synchronized(lock) { loaded }
        if (current == null) {
            // Not downloaded, not loaded yet, or failed to load: leave it.
            warm()
            return null
        }
        val start = System.nanoTime()
        val deadline = start + budget * 1_000_000
        return try {
            val bias = if (sureOnly) GrammarTagger.SURE_KEEP_BIAS else GrammarTagger.KEEP_BIAS
            val corrected = synchronized(current) { current.tagger.correct(text, keep, deadline, bias = bias) }
            when {
                System.nanoTime() > deadline + budget * 1_000_000 -> {
                    // One sentence ran far past the budget (the tagger only
                    // checks between sentences and passes). Its result is still
                    // correct; the log says the phone is slower than assumed.
                    log("grammar_slow")
                    corrected
                }
                corrected.none(Char::isLetter) -> text
                else -> corrected
            }
        } catch (error: Throwable) {
            log("grammar_failed")
            text
        }
    }

    /** Whether a session is loaded and in use. For tests, which otherwise race the loader. */
    internal val isLoaded: Boolean get() = synchronized(lock) { loaded != null }

    /** Frees the session. The next [warm] loads it again. */
    fun release() {
        val previous = synchronized(lock) {
            generation++
            loaded.also { loaded = null }
        } ?: return
        synchronized(previous) { previous.close() }
    }

    /** Forgets a failed load, so a fresh download gets its own attempt. */
    fun modelChanged() {
        synchronized(lock) { failedFor = null }
        release()
    }

    private fun fingerprint(): Long = File(store.modelDirectory, "mindtype_tagger.onnx").lastModified()

    companion object {
        internal fun loadFrom(directory: File): Loaded {
            val tokenizer = ByteLevelBpe.parse(File(directory, "tokenizer.json").readText())
            val labels = JSONArray(File(directory, "labels.json").readText()).let { array ->
                List(array.length()) { array.getString(it) }
            }
            check(labels.size == GrammarTagger.LABEL_COUNT && labels[0] == "KEEP") { "unexpected labels.json" }
            val pairs = JSONArray(File(directory, "plausible_pairs.json").readText()).let { array ->
                List(array.length()) { array.getString(it) }
            }
            val session = GrammarSession.open(File(directory, "mindtype_tagger.onnx"))
            return Loaded(GrammarTagger(tokenizer, labels, pairs, session), session::close)
        }
    }
}
