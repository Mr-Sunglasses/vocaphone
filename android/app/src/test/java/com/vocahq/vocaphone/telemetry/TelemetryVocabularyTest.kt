package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.local.LocalModelDescriptor
import kotlin.reflect.KParameter
import kotlin.reflect.KVisibility
import kotlin.reflect.full.declaredMemberFunctions
import kotlin.reflect.jvm.jvmErasure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the structural half of the privacy promise.
 *
 * `docs/privacy.md` claims a call site *cannot* put private content into an
 * event, rather than that reviewers will notice if it tries. That is only true
 * while [Telemetry] exposes no parameter capable of carrying one.
 */
class TelemetryVocabularyTest {

    /**
     * The only non-enum parameter types [Telemetry] may accept.
     *
     * `Boolean` is safe by construction: two values, neither of them content.
     * [LocalModelDescriptor] is here because the model identifier has to come
     * from somewhere, and taking the descriptor is stronger than taking its id
     * as a string — the value can only originate in the shipped catalog, and
     * `Telemetry.modelDownloadFinished` re-checks it against that catalog
     * before it goes anywhere.
     *
     * Adding to this list is a deliberate widening of what can reach the
     * network. Do it in a commit that says so.
     */
    private val allowedNonEnumTypes = setOf(
        Boolean::class,
        LocalModelDescriptor::class,
    )

    @Test
    fun `no public telemetry function accepts free text`() {
        val offenders = Telemetry::class.declaredMemberFunctions
            .filter { it.visibility == KVisibility.PUBLIC }
            .flatMap { function ->
                function.parameters
                    .filter { it.kind == KParameter.Kind.VALUE }
                    .map { function.name to it.type.jvmErasure }
            }
            .filterNot { (_, type) ->
                type.java.isEnum || type in allowedNonEnumTypes
            }

        assertTrue(
            "Telemetry must not accept unconstrained values. Offending parameters: " +
                offenders.joinToString { "${it.first}(${it.second.simpleName})" } +
                ". A String parameter here is how a transcript, a gateway URL or a " +
                "bearer token reaches the network.",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `every event name is lower_snake_case and stable`() {
        TelemetryEvent.entries.forEach { event ->
            assertTrue(
                "${event.name} has a wire value that will not survive a query: ${event.wire}",
                event.wire.matches(Regex("[a-z][a-z0-9_]*")),
            )
        }
    }

    @Test
    fun `every property value is lower_snake_case`() {
        val values = TelemetrySetupStep.entries.map { it.wire } +
            TelemetrySource.entries.map { it.wire } +
            TelemetryStage.entries.map { it.wire } +
            TelemetryReason.entries.map { it.wire } +
            TelemetryDurationBucket.entries.map { it.wire } +
            TelemetryDownloadOutcome.entries.map { it.wire } +
            TelemetryQuality.entries.map { it.wire } +
            listOf(TelemetryModelId.GATEWAY, TelemetryModelId.UNKNOWN)

        values.forEach { value ->
            assertTrue(
                "$value will not group cleanly in a query",
                value.matches(Regex("[a-z0-9][a-z0-9_]*")),
            )
        }
    }

    @Test
    fun `wire names are unique within each vocabulary`() {
        fun <T> assertUnique(name: String, wires: List<String>) {
            assertEquals("$name has duplicate wire values", wires.size, wires.toSet().size)
        }

        assertUnique<TelemetryEvent>("TelemetryEvent", TelemetryEvent.entries.map { it.wire })
        assertUnique<TelemetryReason>("TelemetryReason", TelemetryReason.entries.map { it.wire })
        assertUnique<TelemetryStage>("TelemetryStage", TelemetryStage.entries.map { it.wire })
    }

    /**
     * The one-shot set is what the funnel arithmetic divides by, so an event
     * added to [TelemetryEvent.ONE_SHOT] without a `recordOnce` call site -- or
     * the reverse -- silently skews a ratio rather than breaking anything.
     */
    @Test
    fun `one-shot events are the ones the funnel counts`() {
        assertEquals(
            setOf(
                TelemetryEvent.APP_FIRST_OPEN,
                TelemetryEvent.SETUP_STEP_COMPLETED,
                TelemetryEvent.SETUP_FINISHED,
                TelemetryEvent.FIRST_DICTATION_EVER,
            ),
            TelemetryEvent.ONE_SHOT,
        )
    }
}
