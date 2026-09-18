package com.thrw.adapter.android.ui

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationManagerCompat
import com.thrw.adapter.android.R
import com.thrw.adapter.android.AdapterForegroundService
import com.thrw.adapter.android.identity.AdapterProvisioning
import com.thrw.adapter.android.identity.FieldError
import com.thrw.adapter.android.identity.FieldResult
import com.thrw.adapter.android.identity.ProvisioningInput

/**
 * The app's launcher screen (#102): the two things
 * [com.thrw.adapter.android.AdapterForegroundService] needs from a human
 * before it can do anything on real hardware.
 *
 * 1. Provisioning - the relay account id and the bonded headset's
 *    Bluetooth address, persisted via [AdapterProvisioning]. Until this
 *    screen existed there was no way to set either short of `adb shell`,
 *    and the service refused to start (correctly) on every boot.
 * 2. The three runtime-dangerous permissions the manifest declares
 *    ([AdapterPermissions]), requested through the platform's
 *    [ActivityResultContracts.RequestMultiplePermissions] contract - which
 *    is also what shows the system's own rationale handling, rather than a
 *    hand-rolled dialog.
 *
 * Starts [com.thrw.adapter.android.AdapterForegroundService] on a
 * successful save, alongside [com.thrw.adapter.android.BootCompletedReceiver]
 * which still starts it on boot.
 *
 * #102 acceptance criterion 4 originally left the boot receiver as the
 * *only* start path, so there was exactly one answer to "what started this
 * service", and accepted that freshly saved provisioning wouldn't take
 * effect until the next reboot. This class's kdoc named the condition for
 * revisiting that - "if the reboot wait proves unacceptable on real
 * hardware" - and it did, during the first real-device test: saving
 * provisioning on a Pixel 10 Pro left the adapter inert, with no way to
 * bring it up short of a reboot. Asking for a restart after every
 * configuration change isn't reasonable, so there are now two start paths.
 * Both funnel through the same `onStartCommand`, which re-reads
 * provisioning from `SharedPreferences` either way - see
 * docs/handoffs/102.md for the original reasoning.
 *
 * Note this screen covers *runtime* permissions only. Notification-listener
 * access (below, #107) and pairing the headset itself in Android's
 * Bluetooth settings still have no in-app flow for the pairing step
 * (docs/handoffs/96.md) - the headset field only *picks* an already-bonded
 * device ([BondedHeadsets], #117), it doesn't pair a new one.
 *
 * Notification-listener access (#107) is a different access model from
 * the three runtime permissions above: it's a special-access toggle the
 * user grants manually in a Settings screen
 * ([Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS]), not a
 * [ActivityResultContracts.RequestMultiplePermissions]-style dialog, and
 * there's no programmatic grant - only a deep link to the right screen and
 * a status readout ([NotificationAccess]) once the user comes back.
 * Without it, [AndroidNotificationListenerService] never connects and
 * trigger detection silently degrades with no other signal to the user.
 */
class ProvisioningActivity : ComponentActivity() {
    private lateinit var accountIdField: EditText
    private lateinit var headsetPicker: Spinner
    private lateinit var headsetPickerStatus: TextView
    private lateinit var headsetPickerAdapter: ArrayAdapter<String>
    private lateinit var permissionStatus: TextView
    private lateinit var notificationAccessStatus: TextView

    /**
     * The bonded devices backing [headsetPicker]'s *real* entries - the
     * adapter's position `i + 1` is `bondedDevices[i]`; position `0` is
     * always the placeholder ([R.string.headset_picker_placeholder]), not
     * a device. Refreshed every [renderHeadsetPicker] call.
     */
    private var bondedDevices: List<BondedDevice> = emptyList()

    private val requestPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // The result map is ignored on purpose: it only covers the
            // permissions in *this* request, whereas the status line below
            // re-reads the live grant state of all of them.
            renderPermissionStatus()
            // BLUETOOTH_CONNECT may have just been granted, which changes
            // whether the picker can read the bonded-device list at all.
            renderHeadsetPicker()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_provisioning)

        accountIdField = findViewById(R.id.account_id)
        headsetPicker = findViewById(R.id.headset_picker)
        headsetPickerStatus = findViewById(R.id.headset_picker_status)
        permissionStatus = findViewById(R.id.permission_status)
        notificationAccessStatus = findViewById(R.id.notification_access_status)

        headsetPickerAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_item)
        headsetPickerAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        headsetPicker.adapter = headsetPickerAdapter

        // Pre-fill with what's already persisted, so this doubles as a
        // settings screen rather than a one-shot setup wizard. The
        // headset picker's own first render happens in onResume, same as
        // the permission/notification-access status lines below - onResume
        // always runs right after onCreate on a fresh launch, so nothing
        // is skipped, and this avoids rendering it twice.
        accountIdField.setText(AdapterProvisioning.accountId(this).orEmpty())

        findViewById<Button>(R.id.save).setOnClickListener { save() }
        findViewById<Button>(R.id.grant_permissions).setOnClickListener { requestMissingPermissions() }
        findViewById<Button>(R.id.open_notification_access_settings).setOnClickListener {
            openNotificationListenerSettings()
        }
    }

    override fun onResume() {
        super.onResume()
        // Permissions can be revoked from system Settings while this
        // activity is stopped, so the status line is recomputed on every
        // resume rather than only after a request. Notification-listener
        // access is granted/revoked in its own separate Settings screen
        // this activity has no result callback for, so it's re-checked
        // here too rather than only right after launching that screen.
        // The bonded-device list can change the same way (the user pairs
        // or unpairs a headset in system Bluetooth settings and comes
        // back), so the picker is refreshed here too, not only in
        // onCreate.
        renderPermissionStatus()
        renderNotificationAccessStatus()
        renderHeadsetPicker()
    }

    private fun save() {
        val accountId = ProvisioningInput.accountId(accountIdField.text.toString())
        // ProvisioningInput.headsetAddress is unchanged (#117 "paths the
        // agent must not touch") - the picker only changes *how* a value
        // reaches it, an empty string when nothing real is selected
        // produces the same FieldError.HEADSET_ADDRESS_BLANK it always
        // has.
        val headsetAddress = ProvisioningInput.headsetAddress(selectedHeadsetAddress().orEmpty())

        accountIdField.error = (accountId as? FieldResult.Invalid)?.let { getString(messageFor(it.error)) }
        if (headsetAddress is FieldResult.Invalid && bondedDevices.isNotEmpty()) {
            // Only overwrite the status line with "pick one" when the
            // picker actually has pickable entries - in the permission-
            // not-granted / no-bonded-devices states that line is already
            // explaining exactly why nothing can be selected, and this
            // would erase a more useful message with a less useful one.
            headsetPickerStatus.text = getString(messageFor(headsetAddress.error))
            headsetPickerStatus.visibility = View.VISIBLE
        }

        // Both fields are validated and flagged above before this returns,
        // so one save press reports every problem at once.
        if (accountId !is FieldResult.Valid || headsetAddress !is FieldResult.Valid) return

        AdapterProvisioning.setAccountId(this, accountId.value)
        AdapterProvisioning.setHeadsetAddress(this, headsetAddress.value)

        // Show the normalized account id (trimmed) - what was actually
        // persisted, not what was typed. The headset picker's own
        // selection already shows exactly what was persisted; nothing to
        // normalize/redisplay there the way the old free-text field
        // needed (address upper-casing).
        accountIdField.setText(accountId.value)

        // Start the service now rather than waiting for the next reboot.
        //
        // #102 acceptance criterion 4 deliberately left BootCompletedReceiver
        // as the only start path, and this class's kdoc named the exact
        // condition for revisiting: "if the reboot wait proves unacceptable
        // on real hardware". It did - on a real Pixel 10 Pro, saving
        // provisioning left the adapter inert with no way to bring it up
        // short of rebooting, which is not a reasonable thing to ask after
        // every configuration change.
        //
        // startForegroundService (not startService): the service calls
        // startForeground() immediately in onStartCommand, which is what
        // Android requires of a background-initiated foreground service.
        // Starting an already-running service is harmless - onStartCommand
        // re-reads provisioning from SharedPreferences, so this doubles as
        // "apply the new settings".
        startForegroundService(Intent(this, AdapterForegroundService::class.java))

        Toast.makeText(this, R.string.provisioning_saved, Toast.LENGTH_LONG).show()
    }

    /**
     * The address of whatever's currently picked in [headsetPicker], or
     * `null` if nothing real is selected - position `0` is always the
     * placeholder ([R.string.headset_picker_placeholder]), and
     * `AdapterView.INVALID_POSITION` (`-1`) is what an empty adapter
     * reports.
     */
    private fun selectedHeadsetAddress(): String? {
        val position = headsetPicker.selectedItemPosition
        if (position <= 0) return null
        return bondedDevices.getOrNull(position - 1)?.address
    }

    /**
     * Repopulates [headsetPicker] from [BondedDeviceSource.bondedDevices]
     * via [BondedHeadsets.state] (#117 acceptance criteria 1-2): shows the
     * picker with a placeholder-first device list, or - for the two
     * non-list states - hides it in favor of an explanatory message in
     * [headsetPickerStatus].
     */
    private fun renderHeadsetPicker() {
        val granted = isGranted(AdapterPermissions.BLUETOOTH_CONNECT)
        val devices = if (granted) BondedDeviceSource.bondedDevices(this) else emptyList()
        bondedDevices = devices

        when (val state = BondedHeadsets.state(granted, devices)) {
            is BondedHeadsetsState.PermissionNotGranted ->
                showHeadsetPickerMessage(R.string.headset_permission_not_granted)

            is BondedHeadsetsState.NoDevicesBonded ->
                showHeadsetPickerMessage(R.string.headset_none_bonded)

            is BondedHeadsetsState.Devices -> {
                headsetPickerStatus.visibility = View.GONE
                headsetPicker.visibility = View.VISIBLE

                headsetPickerAdapter.clear()
                headsetPickerAdapter.add(getString(R.string.headset_picker_placeholder))
                headsetPickerAdapter.addAll(state.devices.map(BondedHeadsets::label))

                // Pre-select whatever's already persisted, if it's still
                // among the bonded devices - otherwise leave the
                // placeholder selected rather than silently assuming the
                // platform's first-listed device.
                val persistedAddress = AdapterProvisioning.headsetAddress(this)
                val matchIndex = state.devices.indexOfFirst { it.address == persistedAddress }
                headsetPicker.setSelection(if (matchIndex >= 0) matchIndex + 1 else 0)
            }
        }
    }

    private fun showHeadsetPickerMessage(messageRes: Int) {
        headsetPicker.visibility = View.GONE
        headsetPickerStatus.visibility = View.VISIBLE
        headsetPickerStatus.text = getString(messageRes)
    }

    private fun requestMissingPermissions() {
        val missing = AdapterPermissions.missing(isGranted = ::isGranted)
        if (missing.isEmpty()) {
            renderPermissionStatus()
            return
        }
        // Requesting an already-denied permission a second time is a no-op
        // the system answers immediately (Android 11+ auto-deny); the
        // status line below is what tells the user to go to Settings.
        requestPermissions.launch(missing.toTypedArray())
    }

    private fun renderPermissionStatus() {
        val missing = AdapterPermissions.missing(isGranted = ::isGranted)
        permissionStatus.text = if (missing.isEmpty()) {
            getString(R.string.permissions_all_granted)
        } else {
            getString(R.string.permissions_missing, missing.joinToString(separator = "\n") { it.substringAfterLast('.') })
        }
    }

    private fun isGranted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun renderNotificationAccessStatus() {
        val granted = NotificationAccess.isGranted(
            packageName = packageName,
            enabledListenerPackages = NotificationManagerCompat.getEnabledListenerPackages(this),
        )
        notificationAccessStatus.text = getString(
            if (granted) R.string.notification_access_granted else R.string.notification_access_missing,
        )
    }

    /**
     * There's no programmatic grant for this special access - only a deep
     * link to the Settings screen where the user grants it by hand.
     * Correcting this method's own prior claim: `Settings` has no public
     * `EXTRA_FRAGMENT_ARG_KEY` field to scope that screen to this app's
     * specific listener row - referencing it doesn't compile
     * (`Unresolved reference`, caught by CI's `android` job after this
     * landed on `main` once already). The row-scoping trick some OEM
     * Settings builds honor relies on a hidden, undocumented extra key
     * (`":settings:fragment_args_key"`) that isn't part of the Android
     * SDK this module compiles against, so it isn't used here. This opens
     * the general notification-access list instead, which is what the
     * issue's own "fallback to the plain settings screen" already asked
     * for as an acceptable outcome.
     */
    private fun openNotificationListenerSettings() {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    private fun messageFor(error: FieldError): Int = when (error) {
        FieldError.ACCOUNT_ID_BLANK -> R.string.error_account_id_blank
        FieldError.ACCOUNT_ID_UNSUPPORTED_CHARACTERS -> R.string.error_account_id_unsupported_characters
        FieldError.HEADSET_ADDRESS_BLANK -> R.string.error_headset_address_blank
        FieldError.HEADSET_ADDRESS_MALFORMED -> R.string.error_headset_address_malformed
    }
}
