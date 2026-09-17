package com.thrw.adapter.android.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.thrw.adapter.android.R
import com.thrw.adapter.android.identity.AdapterProvisioning
import com.thrw.adapter.android.identity.ProvisioningField
import com.thrw.adapter.android.identity.ProvisioningInput
import com.thrw.adapter.android.identity.ProvisioningProblem

/**
 * The app's launcher screen (#102), and the only thing in this codebase
 * that writes [AdapterProvisioning]'s two keys or asks for the three
 * runtime-dangerous permissions `AndroidManifest.xml` declares. Before this
 * existed, both had to be done by hand over `adb` and the app had no
 * launcher `Activity` at all - see docs/handoffs/96.md's "Known gaps".
 *
 * Deliberately does **not** start [com.thrw.adapter.android.AdapterForegroundService]
 * on save. #102's acceptance criterion 4 names
 * [com.thrw.adapter.android.BootCompletedReceiver] as the existing start
 * path and scopes this screen to provisioning plus permissions; the
 * consequence, which the UI states plainly
 * ([R.string.provisioning_restart_note]), is that a freshly provisioned
 * device needs a reboot before the service picks the values up. The service
 * re-reads both keys from `SharedPreferences` on every `onStartCommand`
 * (`AdapterForegroundService.onStartCommand`), so no in-process
 * notification of the change is needed for that to work. See
 * docs/handoffs/102.md for the full reasoning and the follow-up this
 * leaves open.
 *
 * Only the mapping of validated input to persistence lives here; the
 * decidable part - what counts as a valid account id or headset address -
 * is [ProvisioningInput], which is unit tested. This class is not:
 * `Activity` and the real permission dialog need Robolectric or
 * instrumentation, neither of which this module has (docs/handoffs/102.md).
 */
class ProvisioningActivity : ComponentActivity() {
    private lateinit var accountIdField: EditText
    private lateinit var headsetAddressField: EditText
    private lateinit var saveStatus: TextView
    private lateinit var permissionStatus: TextView

    /**
     * The platform's own multi-permission flow
     * (`ActivityResultContracts.RequestMultiplePermissions`), not a
     * hand-rolled rationale dialog - #102's acceptance criterion 2. Android
     * decides whether to show a dialog and whether a re-request is even
     * possible; this callback only reports the outcome.
     */
    private val requestPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            renderPermissionStatus()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_provisioning)

        accountIdField = findViewById(R.id.account_id)
        headsetAddressField = findViewById(R.id.headset_address)
        saveStatus = findViewById(R.id.save_status)
        permissionStatus = findViewById(R.id.permission_status)

        // Pre-fill with whatever is already provisioned, so the screen
        // doubles as "what is this device set to?" rather than only ever
        // being a blank form.
        accountIdField.setText(AdapterProvisioning.accountId(this).orEmpty())
        headsetAddressField.setText(AdapterProvisioning.headsetAddress(this).orEmpty())

        findViewById<Button>(R.id.save).setOnClickListener { save() }
        findViewById<Button>(R.id.request_permissions).setOnClickListener { requestMissingPermissions() }

        // First launch only: ask straight away, since nothing this app does
        // works without these. On a recreate (rotation) the launcher above
        // is already registered and re-asking would be noise.
        if (savedInstanceState == null && missingPermissions().isNotEmpty()) {
            requestMissingPermissions()
        }
    }

    override fun onResume() {
        super.onResume()
        // Permissions can change in system Settings while this screen is
        // backgrounded, so the status is re-read here rather than cached.
        renderPermissionStatus()
    }

    private fun save() {
        val accountId = ProvisioningInput.accountId(accountIdField.text.toString())
        val headsetAddress = ProvisioningInput.headsetAddress(headsetAddressField.text.toString())

        // TextView.setError - the platform's own inline field error, shown
        // next to the offending field and cleared by passing null.
        accountIdField.error = errorTextOrNull(accountId)
        headsetAddressField.error = errorTextOrNull(headsetAddress)

        if (accountId !is ProvisioningField.Valid || headsetAddress !is ProvisioningField.Valid) {
            saveStatus.text = getString(R.string.provisioning_not_saved)
            return
        }

        AdapterProvisioning.save(this, accountId.value, headsetAddress.value)

        // Show the normalized values that were actually persisted (the
        // address is upper-cased, both are trimmed), not the raw text.
        accountIdField.setText(accountId.value)
        headsetAddressField.setText(headsetAddress.value)
        saveStatus.text = getString(R.string.provisioning_saved)
    }

    private fun errorTextOrNull(field: ProvisioningField): CharSequence? = when (field) {
        is ProvisioningField.Valid -> null
        is ProvisioningField.Invalid -> getString(field.problem.messageRes())
    }

    private fun ProvisioningProblem.messageRes(): Int = when (this) {
        ProvisioningProblem.BLANK -> R.string.provisioning_error_blank
        ProvisioningProblem.ACCOUNT_ID_TOO_LONG -> R.string.provisioning_error_account_id_too_long
        ProvisioningProblem.ACCOUNT_ID_ILLEGAL_CHARACTERS -> R.string.provisioning_error_account_id_characters
        ProvisioningProblem.MALFORMED_BLUETOOTH_ADDRESS -> R.string.provisioning_error_headset_address
    }

    private fun requestMissingPermissions() {
        val missing = missingPermissions()
        if (missing.isEmpty()) {
            renderPermissionStatus()
            return
        }
        requestPermissions.launch(missing.toTypedArray())
    }

    private fun renderPermissionStatus() {
        val missing = missingPermissions()
        permissionStatus.text = if (missing.isEmpty()) {
            getString(R.string.provisioning_permissions_granted)
        } else {
            getString(
                R.string.provisioning_permissions_missing,
                missing.joinToString { it.substringAfterLast('.') },
            )
        }
    }

    private fun missingPermissions(): List<String> =
        requiredPermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }

    /**
     * The manifest's three dangerous permissions, minus any that aren't
     * runtime-requestable on this device: `POST_NOTIFICATIONS` only exists
     * from API 33, and on this module's `minSdk` 31/32 floor notifications
     * are granted at install time - requesting it there is rejected
     * immediately and would leave the status text permanently claiming a
     * missing permission the user cannot grant.
     */
    private fun requiredPermissions(): List<String> = buildList {
        add(Manifest.permission.BLUETOOTH_CONNECT)
        add(Manifest.permission.READ_PHONE_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
