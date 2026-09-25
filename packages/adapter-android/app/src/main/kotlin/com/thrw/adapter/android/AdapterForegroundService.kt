package com.thrw.adapter.android

import android.app.Notification
import android.app.PendingIntent
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import com.thrw.adapter.android.audio.MediaSessionHandoverAudioGate
import com.thrw.adapter.android.claim.ArbitrationPause
import com.thrw.adapter.android.claim.ManualClaim
import com.thrw.adapter.android.claim.SharedPreferencesArbitrationPauseStore
import com.thrw.adapter.android.status.ClaimAction
import com.thrw.adapter.android.status.NodeStatus
import com.thrw.adapter.android.status.claimAction
import com.thrw.adapter.android.status.textRes
import com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.config.RelayConfig
import com.thrw.adapter.android.config.RelayCredentials
import com.thrw.adapter.android.identity.AdapterProvisioning
import com.thrw.adapter.android.identity.DeviceIdentity
import com.thrw.adapter.android.mqtt.HiveMqttTransport
import com.thrw.adapter.android.protocol.CommandSequenceGate
import com.thrw.adapter.android.protocol.SharedPreferencesSequenceStore
import com.thrw.adapter.android.triggers.AndroidCallStateSource
import android.content.ComponentName
import com.thrw.adapter.android.triggers.AndroidMediaSessionSource
import com.thrw.adapter.android.triggers.AndroidNotificationListenerService
import com.thrw.adapter.android.triggers.AndroidNotificationSource
import com.thrw.adapter.android.triggers.MediaTriggerMonitor
import com.thrw.adapter.android.triggers.CallTriggerMonitor
import com.thrw.adapter.android.triggers.VoipTriggerMonitor
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch

/**
 * The composition root (#96): constructs a real [AndroidNode] wired to a
 * real [HiveMqttTransport] and [BluetoothConnectionManager], registers it,
 * launches [AndroidNode.listenForCommands], and starts the two trigger
 * monitors - all as a foreground `Service`, since Android requires
 * foreground status for anything that needs to keep running reliably in
 * the background, especially for call/notification-triggered behavior.
 *
 * The untestable half of the composition root - see [NodeRuntime] for the
 * testable half this class delegates to once its real dependencies exist,
 * and docs/handoffs/96.md for what is/isn't covered by tests here.
 *
 * Does not implement the connection state machine (idle/pre-claim/claim/
 * active) - frozen contract per ADR 0010/0011/0013, out of scope here.
 *
 * Started on boot ([BootCompletedReceiver]) rather than on app launch -
 * see that class's kdoc for why.
 */
class AdapterForegroundService : Service() {
    private val job = SupervisorJob()

    /**
     * Last line of defence (#161): without this, *any* unhandled
     * exception in a coroutine launched below reaches the thread's
     * default uncaught handler, which on Android kills the process.
     *
     * A `SupervisorJob` alone is not enough and it's an easy thing to
     * assume otherwise - it stops a failing child cancelling its
     * siblings, but it does not handle the exception. Found the hard way
     * on real hardware: a failed AirPods connect during a genuine relay
     * handoff crashed the whole adapter, and Android restarted it in a
     * loop (`Scheduling restart of crashed service ... in 11000ms`),
     * tearing down and rebuilding the MQTT session each time.
     *
     * Individual failures should still be handled where they're
     * actionable - `AndroidNode.listenForCommands` catches a failed
     * claim so the subscription survives. This exists so that anything
     * missed degrades to a log line instead of process death.
     */
    private val exceptionHandler = CoroutineExceptionHandler { _, e ->
        Log.e(TAG, "Unhandled exception in the node runtime - the adapter stays up", e)
    }
    private val scope = CoroutineScope(job + exceptionHandler)
    private var transport: HiveMqttTransport? = null

    /**
     * The scope for **one** node runtime, so a restart can tear the
     * previous one down (#182).
     *
     * Android calls `onStartCommand` on every service start, and the
     * provisioning screen's Save button starts the service again. Before
     * this, each call built a *second* transport and node runtime in the
     * same process and overwrote [transport] without closing it, leaving
     * two live MQTT clients sharing one client id.
     *
     * That was survivable only because a kicked client used to stay dead:
     * the broker closes the older session when a duplicate id connects,
     * and nothing reconnected it. With automatic reconnect (#182) the two
     * clients fight forever instead - each reconnect kicks the other,
     * observed on a real device as a registration every 1-6 seconds and
     * a continuous stream of "Server closed connection without
     * DISCONNECT". So reconnect turned a quiet latent bug into a loud
     * one, and the fix belongs with it.
     */
    private var runtimeScope: CoroutineScope? = null

    /** #212. Non-null only while a node runtime is running. */
    private var manualClaim: ManualClaim? = null
    /** #290. Non-nil only while a node runtime is running. */
    private var arbitrationPause: ArbitrationPause? = null

    /** The running node, so the notification can ask it for status (#213). */
    private var node: AndroidNode? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android requires startForeground() within a few seconds of a
        // foreground-service start, before any of the async setup below -
        // so this happens first, unconditionally.
        startForegroundWithNotification()

        // #212. A tap on the notification action re-enters here rather
        // than arriving anywhere else - a started service has no other
        // inbound channel. Handled before the provisioning read below so
        // it never restarts the runtime.
        if (intent?.action == ACTION_TOGGLE_CLAIM) {
            val claim = manualClaim
            if (claim == null) {
                Log.w(TAG, "Manual claim tapped with no node running - ignoring")
            } else {
                scope.launch {
                    runCatching { claim.toggle() }
                        .onFailure { Log.e(TAG, "Manual claim failed", it) }
                    refreshNotification()
                }
            }
            return START_STICKY
        }

        // #290. Same shape as the claim toggle above, and handled before
        // the provisioning read for the same reason: it must never
        // restart the runtime.
        if (intent?.action == ACTION_TOGGLE_PAUSE) {
            val pause = arbitrationPause
            if (pause == null) {
                Log.w(TAG, "Pause tapped with no node running - ignoring")
            } else {
                scope.launch {
                    runCatching { pause.toggle() }
                        .onFailure { Log.e(TAG, "Pause toggle failed", it) }
                    refreshNotification()
                }
            }
            return START_STICKY
        }

        val accountId = AdapterProvisioning.accountId(this)
        val headsetAddress = AdapterProvisioning.headsetAddress(this)
        if (accountId == null || headsetAddress == null) {
            // No provisioning UI exists yet (docs/handoffs/96.md) - this is
            // the honest failure mode until one does, rather than silently
            // starting a half-configured node.
            Log.e(TAG, "Not provisioned (accountId=$accountId, headsetAddress=$headsetAddress) - stopping")
            stopSelf(startId)
            return START_NOT_STICKY
        }

        // Tear down any previous runtime before starting another, so a
        // repeated start restarts the node rather than duplicating it.
        val previousScope = runtimeScope
        val previousTransport = transport
        transport = null
        val thisRuntimeScope = CoroutineScope(SupervisorJob(job) + exceptionHandler)
        runtimeScope = thisRuntimeScope

        scope.launch {
            previousScope?.coroutineContext?.get(Job)?.cancelAndJoin()
            previousTransport?.let { runCatching { it.close() } }

            val relayConfig = RelayConfig.fromBuildConfig()
            val nodeId = DeviceIdentity.nodeId(this@AdapterForegroundService)
            val manifest = DeviceIdentity.manifest(this@AdapterForegroundService)

            // #147: null connects anonymously, which the deployed relay
            // rejects - logged so a missing credential is diagnosable
            // rather than looking like a network fault.
            val credentials = RelayCredentials.fromBuildConfig()
            if (credentials == null) {
                Log.e(TAG, "No relay credential configured - see config/adapter.properties (#147)")
            }
            // Wrapped in try/catch with real logging: HiveMQ has no SLF4J
            // binding on Android, so a failed connect (bad credential,
            // refused WebSocket upgrade, unreachable host) produces no
            // output at all and the adapter just sits there looking
            // healthy - a foreground service with a notification and no
            // MQTT session. Found during the first real-device test,
            // where exactly that happened and there was nothing to debug
            // from. Logging the outcome either way is the minimum.
            Log.i(TAG, "Connecting to ${relayConfig.host}:${relayConfig.port} (ws=${relayConfig.webSocket}, tls=${relayConfig.tls}, path=${relayConfig.webSocketPath}) as $nodeId, credentials=${credentials != null}")
            val hiveTransport = try {
                HiveMqttTransport.connect(relayConfig, clientId = nodeId, credentials = credentials)
            } catch (e: Exception) {
                Log.e(TAG, "MQTT connect FAILED", e)
                stopSelf()
                return@launch
            }
            Log.i(TAG, "MQTT connected; registering node $nodeId on account $accountId")
            transport = hiveTransport

            val bluetooth = BluetoothConnectionManager(AndroidBluetoothClassicGateway(this@AdapterForegroundService))
            // #210: the persisted high-water mark. In-memory is
            // AndroidNode's default and is not enough here - Android
            // kills and restarts this service routinely, and a mark
            // that died with the process would let the broker's QoS 1
            // redelivery re-run a command already acted on.
            val sequenceGate = CommandSequenceGate(
                SharedPreferencesSequenceStore(this@AdapterForegroundService),
            )
            // #290. One store instance, shared between the node (which
            // reads it on every emit) and the ArbitrationPause the
            // notification toggles.
            val pauseStore = SharedPreferencesArbitrationPauseStore(this@AdapterForegroundService)
            val node = AndroidNode(
                accountId,
                nodeId,
                headsetAddress,
                hiveTransport,
                bluetooth,
                sequenceGate = sequenceGate,
                // ADR 0022 (#254). Uses the same notification-listener
                // grant the VoIP and media triggers already need, so this
                // adds no new permission - which is most of why ADR 0022
                // pauses here while macOS mutes.
                audioGate = MediaSessionHandoverAudioGate(
                    this@AdapterForegroundService,
                    ComponentName(
                        this@AdapterForegroundService,
                        AndroidNotificationListenerService::class.java,
                    ),
                ),
                pauseStore = pauseStore,
            )

            val callMonitor = CallTriggerMonitor(AndroidCallStateSource(this@AdapterForegroundService), node)
            val voipMonitor = VoipTriggerMonitor(AndroidNotificationSource(), node)
            // #165: media (rule 4). Uses the notification-listener access
            // the VoIP trigger already required, so no new permission.
            val mediaMonitor = MediaTriggerMonitor(
                AndroidMediaSessionSource(
                    this@AdapterForegroundService,
                    ComponentName(this@AdapterForegroundService, AndroidNotificationListenerService::class.java),
                ),
                node,
            )

            this@AdapterForegroundService.node = node
            manualClaim = ManualClaim(node)
            // #290. Shares the store instance the node reads, so the
            // node's suppression and the notification's label cannot
            // disagree.
            arbitrationPause = ArbitrationPause(node, pauseStore)
            NodeRuntime(node, callMonitor, voipMonitor, mediaMonitor).start(thisRuntimeScope, manifest)
            // #234 criterion 4. After `start`, so the state subscription
            // exists; the flow replays its current value to a late
            // collector, so nothing is missed by not racing it.
            observeHolderChanges(node)
            refreshNotification()
        }

        // Provisioning is re-read from SharedPreferences on every call
        // above rather than taken from `intent`, so a system-redelivered
        // restart (which hands back a null intent, not the original one)
        // behaves identically to a fresh start.
        return START_STICKY
    }

    override fun onDestroy() {
        // Best-effort: on a *fresh*, uncancelled scope, since `job` below
        // is about to be cancelled and would otherwise cancel this before
        // it runs. Android gives a plain Service no way to block onDestroy()
        // for async cleanup (unlike BroadcastReceiver.goAsync()), so this
        // may not finish if the process dies immediately after - documented
        // as a known limitation in docs/handoffs/96.md, not fixed here.
        transport?.let { t -> CoroutineScope(Job()).launch { runCatching { t.close() } } }
        job.cancel()
        super.onDestroy()
    }

    /**
     * Re-posts the notification with current status and action label
     * (#212/#213).
     *
     * Called after a claim toggle, when the runtime starts, and - since
     * #234 - whenever the relay's holder changes. Still **not on a
     * timer**: a periodic refresh would wake the process to keep a
     * string current that is only read when the shade is pulled down,
     * and this is a battery-sensitive foreground service.
     *
     * The holder subscription does not reopen that objection. It is
     * event-driven off a topic this node already subscribes to, so it
     * costs nothing while nothing is happening and fires exactly when
     * the displayed text has stopped being true - the property a timer
     * cannot offer at any interval. Before #234 the status line and the
     * action label simply did not update on a handover the user did not
     * initiate from this device.
     */
    private fun refreshNotification() {
        scope.launch {
            val status = runCatching { node?.status() }.getOrNull()
            val action = runCatching { currentClaimAction() }.getOrNull()
            startForegroundWithNotification(status, action)
        }
    }

    /**
     * #234. Derived from the relay's holder and this node's own
     * triggers, not from `ManualClaim.isHeld()` alone - see
     * [com.thrw.adapter.android.status.claimAction] for the rule and for
     * the bug it replaces.
     */
    private fun currentClaimAction(): ClaimAction? {
        val claim = manualClaim ?: return null
        return claimAction(
            holdsClaim = node?.holdsClaim(),
            manualClaimHeld = claim.isHeld(),
            because = node?.mostRecentTrigger(),
        )
    }

    /**
     * #234 criterion 4. Re-posts the notification whenever the relay's
     * holder changes, so the status text and the action stop being stale
     * the moment a handover happens anywhere - not only when this device
     * is the one that caused it.
     */
    private fun observeHolderChanges(node: AndroidNode) {
        scope.launch {
            node.holderChanges().collect { refreshNotification() }
        }
    }

    private fun startForegroundWithNotification(
        status: NodeStatus? = null,
        claimAction: ClaimAction? = null,
    ) {
        val builder = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(getString(R.string.adapter_notification_title))
            // #213: the status replaces the old static blurb. That text
            // said the same thing whether the adapter was working or had
            // silently lost its connection two hours ago (#182), which is
            // exactly the failure this is meant to make visible.
            .setContentText(getString(status?.textRes ?: R.string.adapter_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)

        // #212. Only once a node exists - an action that silently does
        // nothing is worse than one that is not there.
        //
        // #234 extends that same principle rather than replacing it. A
        // node holding the headset because of `media`, `voip` or `call`
        // gets a **readout, not an action**: it can only end its own
        // triggers, so there is genuinely nothing for a tap to do, and
        // the old label ("Claim Headset", on a device that was already
        // holding it) was the reported bug.
        claimAction?.let { action ->
            if (!action.isEnabled) {
                builder.setSubText(action.title)
                return@let
            }
            val intent = Intent(this, AdapterForegroundService::class.java).setAction(ACTION_TOGGLE_CLAIM)
            val pending = PendingIntent.getService(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(Notification.Action.Builder(null, action.title, pending).build())
        }

        // #290. Always offered once a node is running, whatever the
        // claim action is doing: the situation it exists for - a call on
        // a device thrw cannot see - is exactly when the claim action is
        // a greyed-out readout and would otherwise leave nothing to tap.
        arbitrationPause?.let { pause ->
            val label = getString(
                if (pause.isPaused()) R.string.resume_switching else R.string.pause_switching,
            )
            val intent = Intent(this, AdapterForegroundService::class.java).setAction(ACTION_TOGGLE_PAUSE)
            val pending = PendingIntent.getService(
                this,
                1,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(Notification.Action.Builder(null, label, pending).build())
        }

        val notification = builder.build()

        // minSdk is 31, above the API 29 (Q) floor for the type-aware
        // overload, so no version check is needed before calling it.
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.adapter_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "AdapterForegroundService"

        /**
         * #212. A started service has no inbound channel other than
         * `onStartCommand`, so the notification action re-enters the
         * service with this action rather than going anywhere else.
         */
        const val ACTION_TOGGLE_CLAIM = "com.thrw.adapter.android.TOGGLE_CLAIM"
        const val ACTION_TOGGLE_PAUSE = "com.thrw.adapter.android.TOGGLE_PAUSE"
        private const val NOTIFICATION_CHANNEL_ID = "thrw_adapter"
        private const val NOTIFICATION_ID = 1
    }
}
