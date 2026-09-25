package com.thrw.adapter.android.mqtt

import android.util.Log
import com.hivemq.client.mqtt.MqttClientState
import com.hivemq.client.mqtt.MqttWebSocketConfig
import com.hivemq.client.mqtt.datatypes.MqttQos
import com.hivemq.client.mqtt.mqtt3.Mqtt3BlockingClient
import com.hivemq.client.mqtt.mqtt3.Mqtt3Client
import com.hivemq.client.mqtt.mqtt3.message.auth.Mqtt3SimpleAuth
import com.thrw.adapter.android.config.RelayConfig
import com.thrw.adapter.android.config.RelayCredentials
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.withTimeout

/**
 * [MqttTransport] backed by the HiveMQ MQTT client.
 *
 * MQTT 3.1.1 rather than 5, to match the rest of the system: the relay
 * side (`packages/relay-core/src/mqtt-client.ts`) uses the `mqtt` npm
 * package, whose default `protocolVersion` is 4 (= 3.1.1). ADR 0001
 * specifies the transport, QoS and retained semantics, none of which need
 * MQTT 5.
 *
 * Transport is MQTT over WebSocket/TLS per ADR 0001 whenever the
 * build-time-configured relay URL says so ([RelayConfig.webSocket] /
 * [RelayConfig.tls]) - which the shipped
 * `config/adapter.properties` (`wss://`) does.
 *
 * The HiveMQ client's own calls are blocking, so every one of them is
 * wrapped in `withContext(Dispatchers.IO)` rather than run on the caller's
 * (on Android, potentially main) thread.
 */
class HiveMqttTransport internal constructor(
    private val client: Mqtt3BlockingClient,
    private val hooks: Hooks,
    private val jitter: ReconnectJitter = ReconnectJitter(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : MqttTransport {

    init {
        // Wired here rather than at build time because the listeners are
        // registered on the builder, before this instance exists.
        //
        // The two halves of a reconnect are deliberately not treated
        // alike (ADR 0020, #277). Re-subscribing happens **now**, still
        // on HiveMQ's connected-listener thread, because a node whose
        // SUBSCRIBE has not been re-sent is deaf to claim and release
        // while looking perfectly healthy - the #182 failure. Only the
        // re-registration report is jittered, and it moves onto a
        // coroutine because it has to wait and this callback must not.
        hooks.onReconnect = {
            resubscribeAll()
            scope.launch { reportReregistration() }
        }
    }

    /**
     * State shared with the client's builder-time connect/disconnect
     * listeners (#182). HiveMQ registers those on the *builder*, so they
     * are created before the transport they need to call back into.
     */
    internal class Hooks {
        /** Live subscriptions, re-issued after a reconnect. */
        val subscriptions = ConcurrentHashMap<String, Subscription>()

        /** Set by the transport once constructed. */
        @Volatile
        var onReconnect: (() -> Unit)? = null

        /**
         * Set by the node, to re-register after a reconnect. Invoked
         * after [ReconnectJitter]'s delay, not immediately - see
         * [reportReregistration].
         */
        @Volatile
        var onReconnected: (() -> Unit)? = null

        /**
         * The first CONNECT is not a *re*connect. Without this, the node
         * would register twice at startup - once from NodeRuntime and
         * once from the connected listener firing on the initial connect.
         */
        @Volatile
        var hasConnectedOnce = false
    }

    internal class Subscription(val topic: String, val qos: Int, val onMessage: (String) -> Unit)

    /**
     * #213. CONNECTED alone - the reconnecting states mean publishes are
     * currently failing, which is what the user needs to be told, not
     * smoothed over as "probably fine".
     */
    override fun isConnected(): Boolean = client.state == MqttClientState.CONNECTED

    override fun onReconnected(handler: () -> Unit) {
        hooks.onReconnected = handler
    }

    /**
     * Re-issues every live subscription after a reconnect.
     *
     * Necessary because the session is clean: HiveMQ's automatic
     * reconnect restores the *connection*, not the subscriptions, so
     * without this the client comes back connected and **deaf** - it
     * would never receive another claim or release, while looking
     * perfectly healthy. That silent-deafness failure is the same shape
     * as the bug this issue is about, one layer down.
     *
     * Deliberately *not* jittered, and deliberately not suspending -
     * see [ReconnectJitter], and [reportReregistration] for the half
     * that is.
     */
    private fun resubscribeAll() {
        val async = client.toAsync()
        for (subscription in hooks.subscriptions.values) {
            runCatching {
                async.subscribeWith()
                    .topicFilter(subscription.topic)
                    .qos(mqttQos(subscription.qos))
                    .callback { publish ->
                        subscription.onMessage(String(publish.payloadAsBytes, Charsets.UTF_8))
                    }
                    .send()
            }.onFailure { Log.e(TAG, "re-subscribe to ${subscription.topic} failed", it) }
        }
    }

    /**
     * Tells the node to re-register, after ADR 0020's reconnect jitter.
     *
     * The wait applies here and nowhere else: this is the reconciliation
     * report (#178/#182 - the relay holds its node list in memory, so a
     * node that reconnects silently is connected but invisible), which
     * every node sends at the same instant after a relay restart and
     * which nothing is waiting on in real time. The manual override path
     * does not come through here - it publishes directly - so a user
     * pressing the button never waits on the delay.
     *
     * `internal` so [HiveMqttTransportTest] can drive it directly
     * instead of having to provoke a real broker-level reconnect.
     */
    internal suspend fun reportReregistration() {
        jitter.await()
        hooks.onReconnected?.invoke()
    }

    override suspend fun publish(topic: String, payload: String, qos: Int, retained: Boolean) {
        withContext(Dispatchers.IO) {
            client.publishWith()
                .topic(topic)
                .qos(mqttQos(qos))
                .retain(retained)
                .payload(payload.toByteArray(Charsets.UTF_8))
                .send()
        }
    }

    override fun subscribe(topic: String, qos: Int): Flow<String> = callbackFlow {
        val async = client.toAsync()
        async.subscribeWith()
            .topicFilter(topic)
            .qos(mqttQos(qos))
            .callback { publish -> trySend(String(publish.payloadAsBytes, Charsets.UTF_8)) }
            .send()
            .get()

        awaitClose {
            runCatching { async.unsubscribeWith().topicFilter(topic).send() }
        }
    }.flowOn(Dispatchers.IO)

    override suspend fun close() {
        // Cancelled before the disconnect, so a jittered re-registration
        // still waiting out its delay does not fire against a transport
        // that is on its way down.
        scope.cancel()
        withContext(Dispatchers.IO) { client.disconnect() }
    }

    companion object {
        private fun mqttQos(qos: Int): MqttQos =
            requireNotNull(MqttQos.fromCode(qos)) { "Not a valid MQTT QoS level: $qos" }

        /**
         * Connects to [config]'s relay as [clientId] and returns a
         * connected transport.
         *
         * [clientId] is the node id: the broker's account-scoped ACLs
         * (architecture.md, "MQTT topic design") key off the connecting
         * client, so it must not be randomly generated per process.
         */
        /**
         * How long to wait for a broker to complete the MQTT connect
         * before giving up (#158).
         *
         * HiveMQ's blocking connect has no timeout of its own: if the
         * transport-level handshake never completes, it waits forever.
         * That is exactly what happened on a real device when
         * `netty-codec-http` was missing - a foreground service with a
         * live TLS socket and no MQTT session, indistinguishable from
         * "still connecting", for as long as the app ran. A bounded wait
         * turns any future variant of that into a loud, diagnosable
         * failure instead of a silent hang.
         */
        private const val TAG = "HiveMqttTransport"

        private const val CONNECT_TIMEOUT_MS = 20_000L

        suspend fun connect(
            config: RelayConfig,
            clientId: String,
            credentials: RelayCredentials? = null,
        ): HiveMqttTransport = withContext(Dispatchers.IO) {
            val hooks = Hooks()
            var builder = Mqtt3Client.builder()
                .identifier(clientId)
                .serverHost(config.host)
                .serverPort(config.port)
                // #182. Without this an adapter that loses its connection
                // never comes back: it keeps running, its foreground
                // notification stays up, and every publish throws
                // MqttClientStateException("MQTT client is not
                // connected") forever. That is silent, because #161's
                // crash survivability faithfully keeps the adapter alive
                // while its transport is dead. Observed for real when a
                // relay deploy restarted the broker and neither adapter
                // ever returned. The triggers are mundane - Wi-Fi change,
                // the phone sleeping past the 60s keepalive, any relay
                // deploy.
                .automaticReconnectWithDefaultConfig()
                .addDisconnectedListener { context ->
                    Log.w(
                        TAG,
                        "MQTT disconnected (source=${context.source}); reconnecting",
                        context.cause,
                    )
                }
                .addConnectedListener {
                    if (!hooks.hasConnectedOnce) {
                        hooks.hasConnectedOnce = true
                        return@addConnectedListener
                    }
                    Log.i(TAG, "MQTT reconnected; restoring subscriptions and re-registering")
                    hooks.onReconnect?.invoke()
                }

            if (config.webSocket) {
                builder = builder.webSocketConfig(
                    MqttWebSocketConfig.builder().serverPath(config.webSocketPath).build(),
                )
            }
            if (config.tls) {
                builder = builder.sslWithDefaultConfig()
            }
            // Credentials belong on the *builder*, not on connectWith()
            // below (#182). simpleAuth() on a connect call applies to
            // that one CONNECT; automaticReconnect sends its own, and
            // without this it sends it unauthenticated. Against the
            // deployed broker (allow_anonymous=false) every reconnect
            // then fails with BAD_USER_NAME_OR_PASSWORD forever, so the
            // adapter retries busily and never recovers - which looks
            // exactly like having no reconnect at all. Caught only by
            // testing on a real device against the real relay; the unit
            // tests use a fake transport and cannot see it.
            if (credentials != null) {
                builder = builder.simpleAuth(
                    Mqtt3SimpleAuth.builder()
                        .username(credentials.username)
                        .password(credentials.password.toByteArray())
                        .build(),
                )
            }

            val client = builder.buildBlocking()
            // withTimeout rather than a HiveMQ-level option: the blocking
            // connect below offers none. Cancellation can't interrupt the
            // blocking call itself, but it does free the caller and
            // surfaces a TimeoutCancellationException the service logs,
            // which is the difference between a diagnosable failure and
            // an invisible one.
            // #147: null connects anonymously, which is correct for a
            // local broker with allow_anonymous on (how this module's
            // tests run). The deployed relay sets allow_anonymous=false
            // and rejects that with a NOT_AUTHORIZED connack.
            withTimeout(CONNECT_TIMEOUT_MS) {
                // Auth rides the builder above, so this is the same call
                // whether or not credentials were configured - and,
                // crucially, the same CONNECT that automaticReconnect
                // will re-send on its own.
                client.connect()
            }
            HiveMqttTransport(client, hooks)
        }
    }
}
