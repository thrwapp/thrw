package com.thrw.adapter.android.identity

import android.content.Context
import android.os.Build
import com.thrw.adapter.android.BuildConfig
import com.thrw.adapter.android.protocol.EventKind
import com.thrw.adapter.android.protocol.NodeManifest
import com.thrw.adapter.android.protocol.Platform
import java.util.UUID

/**
 * This device's stable node identity: the [NodeManifest] `AndroidNode.register()`
 * announces, keyed by [nodeId] - which is also the MQTT client id and this
 * node's slot in every per-node topic (architecture.md, "MQTT topic
 * design").
 *
 * [nodeId] must be stable across process restarts - the broker's
 * account-scoped ACLs key off the connecting client id
 * (`HiveMqttTransport.connect`'s kdoc) - so it's generated once and
 * persisted in [PREFS_NAME], not derived fresh on every launch.
 */
object DeviceIdentity {
    private const val PREFS_NAME = "thrw_device_identity"
    private const val KEY_NODE_ID = "node_id"

    fun nodeId(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(KEY_NODE_ID, null)?.let { return it }

        val generated = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_NODE_ID, generated).apply()
        return generated
    }

    /**
     * The manifest this node registers with on connect.
     *
     * [NodeManifest.supportedEventKinds] lists only [EventKind.CALL] and
     * [EventKind.VOIP] - the two triggers this adapter actually has a
     * `triggers/` monitor for ([CallTriggerMonitor]/[VoipTriggerMonitor]).
     * [EventKind.MEDIA] is detected by [com.thrw.adapter.android.triggers.MediaTriggerMonitor]
     * as of #165, so it is advertised too. Previously it had no detector, and
     * [EventKind.MANUAL_CLAIM] isn't something this node spontaneously
     * emits (there's no UI to trigger it) - so neither is claimed here,
     * rather than advertising a capability nothing produces.
     */
    fun manifest(context: Context): NodeManifest = NodeManifest(
        nodeId = nodeId(context),
        platform = Platform.ANDROID,
        displayName = Build.MODEL,
        adapterVersion = BuildConfig.VERSION_NAME,
        supportedEventKinds = listOf(EventKind.CALL, EventKind.VOIP, EventKind.MEDIA),
    )
}
