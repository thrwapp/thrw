package com.thrw.adapter.android.ui

import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.thrw.adapter.android.R
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
 * Deliberately does **not** start [com.thrw.adapter.android.AdapterForegroundService]
 * on save (#102 acceptance criterion 4). [com.thrw.adapter.android.BootCompletedReceiver]
 * is the one start path, and keeping it the only one means there's exactly
 * one answer to "what started this service". The cost is real and worth
 * stating plainly: freshly saved provisioning doesn't take effect until the
 * next reboot, and the screen says so ([R.string.provisioning_saved]) rather
 * than implying the adapter is now live. Changing that is a one-line
 * `startForegroundService` here if the reboot wait proves unacceptable on
 * real hardware - see docs/handoffs/102.md.
 *
 * Note this screen covers *runtime* permissions only. The notification
 * access [com.thrw.adapter.android.triggers.AndroidNotificationListenerService]
 * needs is a Settings toggle with no runtime-permission equivalent, and
 * pairing the headset itself happens in Android's Bluetooth settings - both
 * still have no in-app flow (docs/handoffs/96.md), which is why the address
 * is typed in rather than picked from a list of bonded devices.
 */
class ProvisioningActivity : ComponentActivity() {
    private lateinit var accountIdField: EditText
    private lateinit var headsetAddressField: EditText
    private lateinit var permissionStatus: TextView

    private val requestPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            // The result map is ignored on purpose: it only covers the
            // permissions in *this* request, whereas the status line below
            // re-reads the live grant state of all of them.
            renderPermissionStatus()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_provisioning)

        accountIdField = findViewById(R.id.account_id)
        headsetAddressField = findViewById(R.id.headset_address)
        permissionStatus = findViewById(R.id.permission_status)

        // Pre-fill with what's already persisted, so this doubles as a
        // settings screen rather than a one-shot setup wizard.
        accountIdField.setText(AdapterProvisioning.accountId(this).orEmpty())
        headsetAddressField.setText(AdapterProvisioning.headsetAddress(this).orEmpty())

        findViewById<Button>(R.id.save).setOnClickListener { save() }
        findViewById<Button>(R.id.grant_permissions).setOnClickListener { requestMissingPermissions() }
    }

    override fun onResume() {
        super.onResume()
        // Permissions can be revoked from system Settings while this
        // activity is stopped, so the status line is recomputed on every
        // resume rather than only after a request.
        renderPermissionStatus()
    }

    private fun save() {
        val accountId = ProvisioningInput.accountId(accountIdField.text.toString())
        val headsetAddress = ProvisioningInput.headsetAddress(headsetAddressField.text.toString())

        accountIdField.error = (accountId as? FieldResult.Invalid)?.let { getString(messageFor(it.error)) }
        headsetAddressField.error = (headsetAddress as? FieldResult.Invalid)?.let { getString(messageFor(it.error)) }

        // Both fields are validated and flagged above before this returns,
        // so one save press reports every problem at once.
        if (accountId !is FieldResult.Valid || headsetAddress !is FieldResult.Valid) return

        AdapterProvisioning.setAccountId(this, accountId.value)
        AdapterProvisioning.setHeadsetAddress(this, headsetAddress.value)

        // Show the normalized values (trimmed, address upper-cased) - what
        // was actually persisted, not what was typed.
        accountIdField.setText(accountId.value)
        headsetAddressField.setText(headsetAddress.value)

        Toast.makeText(this, R.string.provisioning_saved, Toast.LENGTH_LONG).show()
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

    private fun messageFor(error: FieldError): Int = when (error) {
        FieldError.ACCOUNT_ID_BLANK -> R.string.error_account_id_blank
        FieldError.ACCOUNT_ID_UNSUPPORTED_CHARACTERS -> R.string.error_account_id_unsupported_characters
        FieldError.HEADSET_ADDRESS_BLANK -> R.string.error_headset_address_blank
        FieldError.HEADSET_ADDRESS_MALFORMED -> R.string.error_headset_address_malformed
    }
}
