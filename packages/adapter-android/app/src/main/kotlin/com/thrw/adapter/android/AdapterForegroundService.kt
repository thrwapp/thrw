package com.thrw.adapter.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import com.thrw.adapter.android.bluetooth.AndroidBluetoothClassicGateway
import com.thrw.adapter.android.bluetooth.BluetoothConnectionManager
import com.thrw.adapter.android.config.RelayConfig
import com.thrw.adapter.android.config.RelayCredentials
import com.thrw.adapter.android.identity.AdapterProvisioning
import com.thrw.adapter.android.identity.DeviceIdentity
import com.thrw.adapter.android.mqtt.HiveMqttTransport
import com.thrw.adapter.android.triggers.AndroidCallStateSource
import com.thrw.adapter.android.triggers.AndroidNotificationSource
import com.thrw.adapter.android.triggers.CallTriggerMonitor
import com.thrw.adapter.android.triggers.VoipTriggerMonitor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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
    private val scope = CoroutineScope(job)
    private var transport: HiveMqttTransport? = null

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

        scope.launch {
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
            val node = AndroidNode(accountId, nodeId, headsetAddress, hiveTransport, bluetooth)

            val callMonitor = CallTriggerMonitor(AndroidCallStateSource(this@AdapterForegroundService), node)
            val voipMonitor = VoipTriggerMonitor(AndroidNotificationSource(), node)

            NodeRuntime(node, callMonitor, voipMonitor).start(scope, manifest)
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

    private fun startForegroundWithNotification() {
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(getString(R.string.adapter_notification_title))
            .setContentText(getString(R.string.adapter_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()

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
        private const val NOTIFICATION_CHANNEL_ID = "thrw_adapter"
        private const val NOTIFICATION_ID = 1
    }
}
