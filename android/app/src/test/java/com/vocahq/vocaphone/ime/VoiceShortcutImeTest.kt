package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.DictationPhase
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceShortcutImeTest {

    @Test
    fun `only an auxiliary voice subtype is the system shortcut`() {
        assertTrue(VoiceShortcutIme.isVoiceShortcutSubtype("voice", auxiliary = true))
        assertTrue(VoiceShortcutIme.isVoiceShortcutSubtype("VOICE", auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("voice", auxiliary = false))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("keyboard", auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("keyboard", auxiliary = false))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype(null, auxiliary = true))
        assertFalse(VoiceShortcutIme.isVoiceShortcutSubtype("", auxiliary = true))
    }

    @Test
    fun `auto-start requires the shortcut, a dictation field, and a free pipeline`() {
        assertTrue(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = false,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = false,
                isBusy = false,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = true,
                alreadyRequested = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
                inputViewShown = false,
            ),
        )
    }

    @Test
    fun `auto-start waits while the IME window is not yet visible`() {
        assertTrue(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = true,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = true,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = false,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = 0,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = true,
                alreadyRequested = false,
                inputViewShown = false,
                waitAttempts = VoiceShortcutIme.MAX_WINDOW_WAITS,
            ),
        )
    }

    @Test
    fun `the normal keyboard never hands back to a previous IME`() {
        val phases = listOf(
            DictationPhase.IDLE,
            DictationPhase.LISTENING,
            DictationPhase.INSERTED,
            DictationPhase.FAILED,
            DictationPhase.READY_TO_INSERT,
        )
        for (phase in phases) {
            assertFalse(
                "non-shortcut $phase should stay on VocaPhone",
                VoiceShortcutIme.shouldReturnToPreviousIme(
                    isVoiceShortcut = false,
                    ownedSession = true,
                    sessionLeftIdle = true,
                    phase = phase,
                ),
            )
        }
    }

    @Test
    fun `shortcut returns after insert, cancel idle, or failed empty`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.FAILED,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.IDLE,
            ),
        )
        assertTrue(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.READY_TO_INSERT,
            ),
        )
    }

    @Test
    fun `shortcut does not bounce back before listening starts`() {
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.IDLE,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = false,
                phase = DictationPhase.LISTENING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.LISTENING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.TRANSCRIBING,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = true,
                sessionLeftIdle = true,
                phase = DictationPhase.PERMISSION_REPAIR,
            ),
        )
    }

    @Test
    fun `a session this shortcut did not start does not steal the keyboard`() {
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = false,
                sessionLeftIdle = true,
                phase = DictationPhase.INSERTED,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = true,
                ownedSession = false,
                sessionLeftIdle = true,
                phase = DictationPhase.IDLE,
            ),
        )
    }

    @Test
    fun `password and other rejected fields still hand back`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = true,
                dictationAllowed = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = true,
                dictationAllowed = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenDictationRejected(
                isVoiceShortcut = false,
                dictationAllowed = false,
            ),
        )
    }

    @Test
    fun `sensitive rejected fields hand back immediately`() {
        assertEquals(
            VoiceShortcutIme.RejectedHandback.IMMEDIATE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = false,
                sensitive = true,
            ),
        )
        assertEquals(
            VoiceShortcutIme.RejectedHandback.NONE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = true,
                sensitive = true,
            ),
        )
    }

    @Test
    fun `late capable EditorInfo after GUIDED cancels bounce and starts`() {
        // Picker / unknown field first → GUIDED delay is armed.
        val guidedDecision = VoiceShortcutIme.rejectedHandback(
            isVoiceShortcut = true,
            dictationAllowed = false,
            sensitive = false,
        )
        assertEquals(VoiceShortcutIme.RejectedHandback.GUIDED, guidedDecision)
        val guided = VoiceShortcutIme.rejectedHandbackEffects(
            decision = guidedDecision,
            alreadyReturned = false,
        )!!
        assertTrue(guided.scheduleDelayedHandback)
        assertTrue(guided.showGuidance)
        assertFalse(guided.requestAutoStart)
        assertFalse(guided.returnImmediately)

        var flags = VoiceShortcutIme.applyRejectedHandbackEffects(
            VoiceShortcutIme.RejectedHandbackFlags(),
            guided,
        )
        assertTrue(flags.delayedPending)
        assertTrue(flags.guidanceVisible)

        // A late StartInput can still deliver a dictation-capable EditorInfo.
        // Live re-check must flip to NONE so the service clears the delayed
        // bounce + guidance and starts — matching the delayed NONE arm.
        val noneDecision = VoiceShortcutIme.rejectedHandback(
            isVoiceShortcut = true,
            dictationAllowed = true,
            sensitive = false,
        )
        assertEquals(VoiceShortcutIme.RejectedHandback.NONE, noneDecision)
        val cleared = VoiceShortcutIme.rejectedHandbackEffects(
            decision = noneDecision,
            alreadyReturned = false,
        )!!
        assertTrue(cleared.cancelDelayedHandback)
        assertFalse(cleared.scheduleDelayedHandback)
        assertFalse(cleared.showGuidance)
        assertTrue(cleared.requestAutoStart)
        assertFalse(cleared.returnImmediately)

        flags = VoiceShortcutIme.applyRejectedHandbackEffects(flags, cleared)
        assertFalse("pending Handler bounce must clear", flags.delayedPending)
        assertFalse("guidance chrome must clear", flags.guidanceVisible)
        assertTrue(
            VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = true,
                dictationAllowed = true,
                isBusy = false,
                alreadyRequested = false,
                inputViewShown = true,
            ),
        )
    }

    @Test
    fun `guided handback is a no-op after return and immediate clears pending`() {
        assertEquals(
            null,
            VoiceShortcutIme.rejectedHandbackEffects(
                decision = VoiceShortcutIme.RejectedHandback.GUIDED,
                alreadyReturned = true,
            ),
        )
        val immediate = VoiceShortcutIme.rejectedHandbackEffects(
            decision = VoiceShortcutIme.RejectedHandback.IMMEDIATE,
            alreadyReturned = false,
        )!!
        val flags = VoiceShortcutIme.applyRejectedHandbackEffects(
            VoiceShortcutIme.RejectedHandbackFlags(
                delayedPending = true,
                guidanceVisible = true,
            ),
            immediate,
        )
        assertFalse(flags.delayedPending)
        assertFalse(flags.guidanceVisible)
        assertTrue(immediate.returnImmediately)
        assertFalse(immediate.requestAutoStart)
    }

    @Test
    fun `picker and unknown editors use guided delayed handback`() {
        assertEquals(
            VoiceShortcutIme.RejectedHandback.GUIDED,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = true,
                dictationAllowed = false,
                sensitive = false,
            ),
        )
        assertEquals(
            VoiceShortcutIme.RejectedHandback.NONE,
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = false,
                dictationAllowed = false,
                sensitive = false,
            ),
        )
        assertTrue(VoiceShortcutIme.REJECTED_HANDBACK_DELAY_MS > 0L)
        assertEquals(
            "Open a text field, then use the host keyboard mic",
            VoiceShortcutIme.REJECTED_HANDBACK_GUIDANCE,
        )
    }

    @Test
    fun `hiding the shortcut view returns even if dictation never started`() {
        assertTrue(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = true,
                alreadyReturned = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = true,
                alreadyReturned = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldReturnWhenViewFinishes(
                isVoiceShortcut = false,
                alreadyReturned = false,
            ),
        )
    }

    @Test
    fun `a hide during auto-start does not bounce back to the typing keyboard`() {
        assertTrue(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = true,
                sessionLeftIdle = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = true,
                sessionLeftIdle = true,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = true,
                startRequested = false,
                sessionLeftIdle = false,
            ),
        )
        assertFalse(
            VoiceShortcutIme.shouldKeepShortcutSession(
                isVoiceShortcut = false,
                startRequested = true,
                sessionLeftIdle = false,
            ),
        )
    }

    @Test
    fun `the voice shortcut does not take a microphone foreground service`() {
        assertFalse(VoiceShortcutIme.usesMicrophoneForegroundService(isVoiceShortcut = true))
        assertTrue(VoiceShortcutIme.usesMicrophoneForegroundService(isVoiceShortcut = false))
    }

    @Test
    fun `voice mode string matches method xml`() {
        assertEquals("voice", VoiceShortcutIme.MODE_VOICE)
        assertEquals("voice", ImeMethodXml.forSdk(33).voice.mode)
        assertEquals("voice", ImeMethodXml.forSdk(34).voice.mode)
    }

    @Test
    fun `IME metadata points at xml method so API 34 selects xml-v34`() {
        val manifest = appFile("src/main/AndroidManifest.xml").readText()
        assertTrue(
            "the IME service must point at @xml/method so the platform applies -v34",
            manifest.contains("""android:resource="@xml/method""""),
        )
        assertFalse("do not hardcode xml-v34 in the manifest", manifest.contains("xml-v34"))
        assertEquals("xml", ImeMethodXml.forSdk(33).qualifier)
        assertEquals("xml-v34", ImeMethodXml.forSdk(34).qualifier)
        assertEquals("xml-v34", ImeMethodXml.forSdk(36).qualifier)
    }

    @Test
    fun `API 33 keeps the voice override so HeliBoard can discover the shortcut`() {
        val method = ImeMethodXml.forSdk(33)
        assertEquals("xml", method.qualifier)
        assertTrue(method.keyboard.overridesImplicitlyEnabledSubtype)
        assertTrue(method.voice.isAuxiliary)
        assertEquals("voice", method.voice.mode)
        assertTrue(
            "API 33 has no setExplicitlyEnabled API; voice must keep the override so HeliBoard sees it",
            method.voice.overridesImplicitlyEnabledSubtype,
        )
        assertEquals("VocaPhone keyboard", method.keyboard.resolvedLabel)
        assertEquals("VocaPhone voice input", method.voice.resolvedLabel)
        // AOSP InputMethodSubtypeSwitchingController blanks subtypeName when
        // overridesImplicitlyEnabledSubtype is set, so both long-press rows
        // fall back to the IME label on API 33.
        assertEquals(listOf("VocaPhone keyboard", "VocaPhone keyboard"), method.pickerImeNames)
        assertEquals(listOf(null, null), method.pickerSubtypeNames)
    }

    @Test
    fun `API 34 selects xml-v34 so the long-press picker can show distinct labels`() {
        val method = ImeMethodXml.forSdk(34)
        assertEquals("xml-v34", method.qualifier)
        assertTrue(method.keyboard.overridesImplicitlyEnabledSubtype)
        assertTrue(method.voice.isAuxiliary)
        assertEquals("voice", method.voice.mode)
        assertFalse(
            "omit voice override so AOSP can show voice_input_label instead of a null subtypeLabel",
            method.voice.overridesImplicitlyEnabledSubtype,
        )
        assertEquals("VocaPhone keyboard", method.keyboard.resolvedLabel)
        assertEquals("VocaPhone voice input", method.voice.resolvedLabel)
        assertEquals(listOf("VocaPhone keyboard", "VocaPhone keyboard"), method.pickerImeNames)
        assertEquals(listOf(null, "VocaPhone voice input"), method.pickerSubtypeNames)
    }

    @Test
    fun `publishing subtypes is a no-op without a manager or info`() {
        // API 34+ setExplicitlyEnabledInputMethodSubtypes enables the voice
        // shortcut after process start (Application + IME onCreate). That is
        // not a guarantee of a single picker row: AOSP INCLUDE_AUXILIARY
        // long-press can still list both enabled subtypes.
        VoiceShortcutIme.publishEnabledSubtypes(null, "com.vocahq.vocaphone/.ime.VocaPhoneInputMethodService", null)
    }

    /**
     * The method.xml Android actually loads at a given SDK, plus the picker
     * labels AOSP would show. Version matching follows the -vN rule: drop
     * overlays newer than the device, then take the highest remaining version.
     *
     * Picker subtypeName is AOSP InputMethodSubtypeSwitchingController:
     * `overridesImplicitlyEnabledSubtype ? null : getDisplayName(...)`.
     */
    private class ImeMethodXml(
        val qualifier: String,
        val keyboard: Subtype,
        val voice: Subtype,
    ) {
        data class Subtype(
            val mode: String,
            val resolvedLabel: String,
            val isAuxiliary: Boolean,
            val overridesImplicitlyEnabledSubtype: Boolean,
        )

        val pickerImeNames: List<String> = listOf(IME_NAME, IME_NAME)
        val pickerSubtypeNames: List<String?> = listOf(
            pickerSubtypeName(keyboard),
            pickerSubtypeName(voice),
        )

        companion object {
            private const val IME_NAME = "VocaPhone keyboard"
            private const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

            fun forSdk(sdk: Int): ImeMethodXml {
                val (qualifier, file) = methodXmlForSdk(sdk)
                val strings = stringResources()
                val subtypes = parseSubtypes(file).map { attrs ->
                    Subtype(
                        mode = attrs.getValue("imeSubtypeMode"),
                        resolvedLabel = resolveString(attrs.getValue("label"), strings),
                        isAuxiliary = attrs["isAuxiliary"] == "true",
                        overridesImplicitlyEnabledSubtype =
                            attrs["overridesImplicitlyEnabledSubtype"] == "true",
                    )
                }
                assertEquals("keep both keyboard and voice subtypes", 2, subtypes.size)
                return ImeMethodXml(
                    qualifier = qualifier,
                    keyboard = subtypes.single { it.mode == "keyboard" },
                    voice = subtypes.single { it.mode == "voice" },
                )
            }

            private fun pickerSubtypeName(subtype: Subtype): String? =
                if (subtype.overridesImplicitlyEnabledSubtype) null else subtype.resolvedLabel

            private fun methodXmlForSdk(sdk: Int): Pair<String, File> {
                val res = appFile("src/main/res")
                val matched = res.listFiles()
                    .orEmpty()
                    .filter { it.isDirectory && (it.name == "xml" || it.name.startsWith("xml-")) }
                    .mapNotNull { dir ->
                        val file = File(dir, "method.xml")
                        if (!file.isFile) return@mapNotNull null
                        val version = versionQualifier(dir.name)
                        if (version != null && version > sdk) return@mapNotNull null
                        Triple(version ?: 0, dir.name, file)
                    }
                val best = matched.maxByOrNull { it.first }
                assertNotNull("no method.xml matches SDK $sdk under ${res.absolutePath}", best)
                return best!!.second to best.third
            }

            private fun versionQualifier(dirName: String): Int? {
                if (dirName == "xml") return null
                val match = Regex("""(?:^|-)v(\d+)$""").find(dirName) ?: return null
                return match.groupValues[1].toInt()
            }

            private fun parseSubtypes(file: File): List<Map<String, String>> {
                val factory = javax.xml.parsers.DocumentBuilderFactory.newInstance().apply {
                    isNamespaceAware = true
                    isIgnoringComments = true
                }
                val document = factory.newDocumentBuilder().parse(file)
                val nodes = document.getElementsByTagName("subtype")
                return (0 until nodes.length).map { index ->
                    val element = nodes.item(index) as org.w3c.dom.Element
                    val attrs = mutableMapOf<String, String>()
                    val named = element.attributes
                    for (i in 0 until named.length) {
                        val attr = named.item(i)
                        val name = if (attr.namespaceURI == ANDROID_NS) attr.localName else attr.nodeName
                        attrs[name] = attr.nodeValue
                    }
                    attrs
                }
            }

            private fun stringResources(): Map<String, String> {
                val xml = appFile("src/main/res/values/strings.xml").readText()
                return Regex("""<string name="([^"]+)">([^<]*)</string>""")
                    .findAll(xml)
                    .associate { it.groupValues[1] to it.groupValues[2] }
            }

            private fun resolveString(ref: String, strings: Map<String, String>): String {
                val name = ref.removePrefix("@string/")
                val value = strings[name]
                assertNotNull("missing string resource $ref", value)
                return value!!
            }
        }
    }

    companion object {
        private fun appFile(relativeFromApp: String): File {
            val direct = listOf(
                File(relativeFromApp),
                File("app/$relativeFromApp"),
                File("android/app/$relativeFromApp"),
            ).firstOrNull { it.isFile || it.isDirectory }
            if (direct != null) return direct
            val walked = generateSequence(File("").absoluteFile) { it.parentFile }
                .map { File(it, "android/app/$relativeFromApp") }
                .firstOrNull { it.isFile || it.isDirectory }
            assertNotNull("cannot find $relativeFromApp from ${File("").absolutePath}", walked)
            return walked!!
        }
    }
}
