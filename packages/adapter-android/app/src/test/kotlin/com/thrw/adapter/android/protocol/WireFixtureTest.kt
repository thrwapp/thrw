package com.thrw.adapter.android.protocol

import com.thrw.adapter.android.bluetooth.COMMAND_OUTCOME_TIMEOUT_MS
import com.thrw.adapter.android.heartbeat.HeartbeatPublisher
import com.thrw.adapter.android.registration.RegistrationPublisher
import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Asserts this adapter's **payload** types against the shared fixture at
 * `packages/protocol/fixtures/wire.json` (#317).
 *
 * [TopicsFixtureTest] next door does this for topic strings (#171) and
 * stops there. The message bodies are hand-written three times —
 * TypeScript across `packages/protocol` and `packages/relay-core`, Swift
 * in `adapter-mac`'s `Payloads.swift`, and this adapter's [Payloads] —
 * and `Payloads.kt`'s own kdoc says nothing catches them drifting. This
 * is that something.
 *
 * ## What is asserted, and in which direction
 *
 * The fixture's `directions` section splits messages by who sends them:
 *
 * - **`nodeToRelay`** — this adapter *sends* these, so it must encode to
 *   exactly the fixture object. The stronger assertion.
 * - **`relayToNode`** — this adapter only *receives* these, so it must
 *   decode them without loss.
 *
 * The split exists because holding a receiver to an encode it never
 * performs fails falsely. Kotlin happens to survive re-encoding
 * `stateNoHolder` (`encodeDefaults = true` emits the explicit null),
 * where Swift's synthesised encoder omits a nil Optional and would
 * produce `{}`. Asserting per direction means the fixture does not have
 * to be shaped around whichever language is fussier.
 *
 * ## What is deliberately *not* asserted
 *
 * The **priority ranking** of [EventKind]. The fixture lists the kinds in
 * priority order because the relay needs that order, but architecture.md
 * requires priority rules to live server-side, "never duplicated in
 * adapters" — so this asserts the *set* of wire spellings and says
 * nothing about their order. Asserting the order here would be a test
 * enforcing the opposite of the architecture.
 */
class WireFixtureTest {

    private val fixture: JsonObject by lazy {
        // Walked up from the module directory rather than copied into test
        // resources: a copy is a second source of truth, which is the
        // thing this test exists to prevent.
        val file = File(System.getProperty("user.dir"))
            .resolve("../../protocol/fixtures/wire.json")
            .normalize()
        check(file.exists()) { "shared wire fixture not found at $file" }
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    private fun section(name: String): JsonObject =
        requireNotNull(fixture[name]) { "fixture has no `$name` section" }.jsonObject

    private fun constant(name: String): Long =
        section("constants").getValue(name).jsonPrimitive.content.toLong()

    private fun vocabulary(name: String): Set<String> =
        section("vocabularies").getValue(name).jsonArray.map { it.jsonPrimitive.content }.toSet()

    /**
     * One canonical wire object, with the reader-facing `$comment`
     * stripped — it is documentation, never a wire field.
     */
    private fun message(name: String): JsonObject {
        val raw = requireNotNull(section("messages")[name]) {
            "fixture has no message named `$name`"
        }.jsonObject
        return JsonObject(raw.filterKeys { it != "\$comment" })
    }

    /**
     * Encodes [value] and compares it to the fixture object as **parsed
     * JSON**, not as text: key order is not part of the wire contract, and
     * comparing serialised strings would fail on a reordering that changes
     * nothing. [ProtocolJson] rather than a default `Json` because that is
     * what the adapter actually publishes with — `encodeDefaults = true`
     * is what puts the `kind` discriminator on the wire at all.
     */
    private fun <T> assertEncodes(serializer: KSerializer<T>, value: T, toMessage: String) {
        assertEquals(
            message(toMessage),
            encoded(serializer, value),
            "does not encode to the shared fixture's `$toMessage`",
        )
    }

    private fun <T> encoded(serializer: KSerializer<T>, value: T): JsonObject =
        ProtocolJson.encodeToJsonElement(serializer, value).jsonObject

    /** The authoritative wire spelling of an enum case: its `@SerialName`. */
    private fun <T> wireNames(serializer: KSerializer<T>): Set<String> =
        (0 until serializer.descriptor.elementsCount)
            .map { serializer.descriptor.getElementName(it) }
            .toSet()

    // ---- Shared constants ----

    /**
     * The one number #206 criterion 2 is explicit about: an adapter that
     * picked its own bound would make the aggregate switch success rate
     * meaningless, because an outcome would not mean the same thing in
     * every row. Three hand-written declarations, now one assertion.
     */
    @Test
    fun `command outcome timeout matches the shared fixture`() {
        assertEquals(constant("commandOutcomeTimeoutMs"), COMMAND_OUTCOME_TIMEOUT_MS)
    }

    /**
     * `HeartbeatPublisher` carries the same "must stay equal" warning as
     * the bound above, about this number.
     */
    @Test
    fun `heartbeat interval matches the shared fixture`() {
        assertEquals(constant("heartbeatIntervalMs"), HeartbeatPublisher.DEFAULT_INTERVAL_MS)
    }

    /**
     * #325. The third shared cadence, and the one #317 missed — the two it
     * caught had source comments complaining about drift and
     * [RegistrationPublisher] does not.
     *
     * This matters more than the heartbeat interval: the relay's 300s
     * `DEFAULT_NODE_DEPARTURE_TIMEOUT_MS` is the knee of the *observed*
     * gap distribution measured against this nominal, so a drift between
     * the two adapter declarations would leave that timer tuned against a
     * distribution describing neither device. The symptom would be a
     * healthy node reaped or a departed one lingering, with nothing
     * pointing at the cause.
     *
     * The fixture's own comment carries that distribution, and it is
     * nothing like 120s — see it before modelling anything on this number.
     */
    @Test
    fun `registration interval matches the shared fixture`() {
        assertEquals(constant("registrationIntervalMs"), RegistrationPublisher.DEFAULT_INTERVAL_MS)
    }

    // ---- Closed vocabularies ----

    /**
     * Both directions, which Kotlin enums give for free via `entries`:
     * every wire spelling in the fixture must exist as a case, **and**
     * every case must appear in the fixture. Without the second half this
     * adapter could grow a kind the relay has never heard of and no test
     * would notice.
     *
     * Set comparison, deliberately — see the class kdoc on why the order
     * of `eventKinds` must not be asserted here.
     */
    @Test
    fun `event kinds match the shared fixture as a set`() {
        assertEquals(vocabulary("eventKinds"), wireNames(EventKind.serializer()))
        assertEquals(EventKind.entries.size, vocabulary("eventKinds").size)
    }

    @Test
    fun `command types match the shared fixture`() {
        assertEquals(vocabulary("commandTypes"), wireNames(CommandType.serializer()))
    }

    @Test
    fun `resource types match the shared fixture`() {
        assertEquals(vocabulary("resourceTypes"), wireNames(ResourceType.serializer()))
        assertEquals(vocabulary("resourceTypes"), ResourceType.entries.map { it.wire }.toSet())
        assertEquals(RESOURCE_AUDIO, ResourceType.AUDIO.wire)
    }

    @Test
    fun `platforms match the shared fixture`() {
        assertEquals(vocabulary("platforms"), wireNames(Platform.serializer()))
    }

    /**
     * Wire spelling, not identifier spelling. Kotlin's case is `TIMED_OUT`
     * and it must serialise as `timed_out`; a mirror that shipped the
     * identifier would be rejected silently by everything downstream.
     */
    @Test
    fun `outcomes and reasons match the shared fixture`() {
        assertEquals(vocabulary("outcomes"), CommandOutcome.entries.map { it.wire }.toSet())
        assertEquals("timed_out", CommandOutcome.TIMED_OUT.wire)
        assertEquals(
            vocabulary("failureReasons"),
            CommandFailureReason.entries.map { it.wire }.toSet(),
        )
    }

    @Test
    fun `kind discriminators match the shared fixture`() {
        val kinds = section("kinds")
        assertEquals(kinds.getValue("register").jsonPrimitive.content, REGISTRATION_KIND)
        assertEquals(kinds.getValue("eventEnd").jsonPrimitive.content, EVENT_END_KIND)
        assertEquals(kinds.getValue("commandOutcome").jsonPrimitive.content, COMMAND_OUTCOME_KIND)
    }

    // ---- node -> relay: this adapter must encode these exactly ----

    @Test
    fun `event encodes to the shared fixture`() {
        val raw = message("event")
        assertEncodes(
            EventPayload.serializer(),
            EventPayload(
                type = eventKind(raw.getValue("type").jsonPrimitive.content),
                priority = raw.getValue("priority").jsonPrimitive.content.toInt(),
            ),
            "event",
        )
    }

    /**
     * An ordinary event carries **no** `kind`. That absence is what makes
     * the discriminator on the other shapes backward-compatible: adding a
     * kind cannot change how an existing event parses
     * (docs/handoffs/67.md).
     */
    @Test
    fun `event carries no kind discriminator`() {
        assertNull(message("event")["kind"])
    }

    /** No `priority`: ending a trigger needs only its kind. */
    @Test
    fun `event end encodes to the shared fixture`() {
        val raw = message("eventEnd")
        assertEncodes(
            EventEndPayload.serializer(),
            EventEndPayload(type = eventKind(raw.getValue("type").jsonPrimitive.content)),
            "eventEnd",
        )
        assertNull(raw["priority"])
    }

    @Test
    fun `registration encodes to the shared fixture`() {
        assertRegistrationEncodes("registration")
    }

    /**
     * The absent-route and empty-`activeEvents` case. `observedRoutes`
     * absence means *cannot determine* and leaves the relay's record
     * alone; `false` positively asserts this node does not hold the
     * resource. Collapsing the two hands the relay a fabricated
     * disagreement (#191), and a node reporting `{}` repeatedly is #303's
     * signature — which the relay has to be able to tell from a denial.
     */
    @Test
    fun `registration with no known route encodes to the shared fixture`() {
        assertRegistrationEncodes("registrationNoRouteKnown")
        val raw = message("registrationNoRouteKnown")
        assertTrue(raw.getValue("observedRoutes").jsonObject.isEmpty())
        assertTrue(raw.getValue("activeEvents").jsonArray.isEmpty())
    }

    private fun assertRegistrationEncodes(name: String) {
        val raw = message(name)
        val manifestJson = raw.getValue("manifest").jsonObject

        val manifest = NodeManifest(
            nodeId = manifestJson.getValue("nodeId").jsonPrimitive.content,
            platform = Platform.entries.first {
                wireName(Platform.serializer(), it.ordinal) ==
                    manifestJson.getValue("platform").jsonPrimitive.content
            },
            displayName = manifestJson.getValue("displayName").jsonPrimitive.content,
            adapterVersion = manifestJson.getValue("adapterVersion").jsonPrimitive.content,
            supportedEventKinds = manifestJson.getValue("supportedEventKinds").jsonArray
                .map { eventKind(it.jsonPrimitive.content) },
            supportedResourceTypes = manifestJson.getValue("supportedResourceTypes").jsonArray
                .map { spelling -> ResourceType.entries.first { it.wire == spelling.jsonPrimitive.content } },
        )

        assertEncodes(
            RegistrationPayload.serializer(),
            RegistrationPayload(
                manifest = manifest,
                activeEvents = raw.getValue("activeEvents").jsonArray
                    .map { eventKind(it.jsonPrimitive.content) },
                observedRoutes = raw.getValue("observedRoutes").jsonObject
                    .mapValues { (_, value) -> value.jsonPrimitive.content.toBoolean() },
            ),
            name,
        )
    }

    /**
     * Every outcome shape at once, reporting **all** mismatches rather
     * than only the first. Failing on the first hid two further
     * divergences behind one message when this test was written, and an
     * incomplete failure report is how a second bug survives the fix for
     * the first.
     */
    @Test
    fun `command outcomes encode to the shared fixture`() {
        val mismatches = mutableListOf<String>()
        for (name in listOf(
            "commandOutcomeSucceeded",
            "commandOutcomeFailed",
            "commandOutcomeSuperseded",
            "commandOutcomeTimedOut",
            "commandOutcomeUnsequenced",
        )) {
            val raw = message(name)
            val actual = encoded(
                CommandOutcomePayload.serializer(),
                CommandOutcomePayload(
                    epoch = raw["epoch"]?.jsonPrimitive?.content,
                    seq = raw["seq"]?.jsonPrimitive?.content?.toLong(),
                    resourceType = raw.getValue("resourceType").jsonPrimitive.content,
                    outcome = raw.getValue("outcome").jsonPrimitive.content,
                    reason = raw["reason"]?.jsonPrimitive?.content,
                    durationMs = raw.getValue("durationMs").jsonPrimitive.content.toLong(),
                ),
            )
            if (actual != raw) mismatches += "$name:\n  expected $raw\n  actual   $actual"
        }
        assertTrue(
            mismatches.isEmpty(),
            "outcome payloads do not encode to the shared fixture:\n" +
                mismatches.joinToString("\n"),
        )
    }

    /**
     * ADR 0019's bound, as a number rather than as prose: the fixture's
     * `timed_out` message must carry exactly the shared timeout, or the
     * two halves of the contract have drifted from each other.
     */
    @Test
    fun `timed out outcome carries the shared bound`() {
        val raw = message("commandOutcomeTimedOut")
        assertEquals(
            constant("commandOutcomeTimeoutMs"),
            raw.getValue("durationMs").jsonPrimitive.content.toLong(),
        )
        assertEquals(CommandOutcome.TIMED_OUT.wire, raw.getValue("outcome").jsonPrimitive.content)
        assertNull(raw["reason"], "timed_out is its own outcome, not a failure with a reason")
    }

    /**
     * An outcome for a command that carried neither `epoch` nor `seq` must
     * still be publishable, or acting on such a command becomes an
     * unmeasurable switch — the exact gap ADR 0019 exists to close.
     */
    @Test
    fun `unsequenced outcome omits epoch and seq`() {
        val raw = message("commandOutcomeUnsequenced")
        assertNull(raw["epoch"])
        assertNull(raw["seq"])
    }

    // ---- relay -> node: this adapter must decode these without loss ----

    @Test
    fun `command decodes from the shared fixture`() {
        val raw = message("command")
        val decoded = ProtocolJson.decodeFromString(CommandPayload.serializer(), raw.toString())
        assertEquals(raw.getValue("type").jsonPrimitive.content, decoded.type.name.lowercase())
        assertEquals(raw.getValue("seq").jsonPrimitive.content.toLong(), decoded.seq)
        assertEquals(raw.getValue("epoch").jsonPrimitive.content, decoded.epoch)
    }

    /**
     * A command carrying neither `epoch` nor `seq` must still decode and
     * be acted on. Not defensive padding: the relay half of #210 shipped
     * before the adapter half, so builds exist that ran against a relay
     * stamping nothing, and [CommandSequenceGate] treats an unsequenced
     * command as acceptable rather than stale.
     */
    @Test
    fun `unsequenced command decodes from the shared fixture`() {
        val raw = message("commandUnsequenced")
        val decoded = ProtocolJson.decodeFromString(CommandPayload.serializer(), raw.toString())
        assertEquals(raw.getValue("type").jsonPrimitive.content, decoded.type.name.lowercase())
        assertNull(decoded.seq)
        assertNull(decoded.epoch)
    }

    @Test
    fun `state decodes from the shared fixture`() {
        val raw = message("state")
        val decoded = ProtocolJson.decodeFromString(StatePayload.serializer(), raw.toString())
        assertEquals(raw.getValue("holder").jsonPrimitive.content, decoded.holder)
    }

    /**
     * `{"holder": null}` is a real answer the relay genuinely publishes
     * when nobody holds the resource, and it must decode to a null holder
     * rather than throwing. `HolderState` is what keeps that distinct from
     * "we have not heard from the relay at all" — conflating the two makes
     * the notification assert confidently that nobody holds the headset
     * when the truth is that it has no idea (#308's family of bug).
     */
    @Test
    fun `explicit null holder decodes from the shared fixture`() {
        val raw = message("stateNoHolder")
        assertTrue(raw.containsKey("holder"), "the fixture must carry an explicit null")
        assertEquals(JsonNull, raw.getValue("holder"))

        val decoded = ProtocolJson.decodeFromString(StatePayload.serializer(), raw.toString())
        assertNull(decoded.holder)
    }

    /**
     * The fixture's `directions` section decides whether a message is
     * asserted by encoding or by decoding, so a message added without a
     * direction would silently be covered by neither.
     */
    @Test
    fun `every fixture message is directed`() {
        val directions = section("directions")
        val directed = listOf("nodeToRelay", "relayToNode")
            .flatMap { directions.getValue(it).jsonArray.map { name -> name.jsonPrimitive.content } }
            .toSet()
        val defined = section("messages").keys - "\$comment"
        assertEquals(defined, directed)
    }

    // ---- helpers ----

    private fun eventKind(wire: String): EventKind =
        EventKind.entries.first { wireName(EventKind.serializer(), it.ordinal) == wire }

    private fun <T> wireName(serializer: KSerializer<T>, ordinal: Int): String =
        serializer.descriptor.getElementName(ordinal)
}
