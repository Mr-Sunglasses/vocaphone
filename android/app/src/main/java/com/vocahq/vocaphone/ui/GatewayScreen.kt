package com.vocahq.vocaphone.ui

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.GatewayEndpoint
import com.vocahq.vocaphone.core.PairingPayload
import com.vocahq.vocaphone.settings.VocaPhoneSettings

@Composable
fun GatewayScreen(
    settings: VocaPhoneSettings,
    connection: ConnectionReport?,
    testing: Boolean,
    inOnboarding: Boolean,
    onSave: (String, String, (String?) -> Unit) -> Unit,
    onTest: () -> Unit,
    onClear: () -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    var url by remember(settings.gatewayUrl) { mutableStateOf(settings.gatewayUrl) }
    var token by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    val submit = {
        focusManager.clearFocus()
        onSave(url, token) { failure ->
            error = failure
            if (failure == null) token = ""
        }
    }

    val scanLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode != Activity.RESULT_OK) {
            val message = result.data?.getStringExtra(QrPairingActivity.EXTRA_ERROR)
            if (!message.isNullOrBlank()) error = message
            return@rememberLauncherForActivityResult
        }
        val raw = result.data?.getStringExtra(QrPairingActivity.EXTRA_RAW).orEmpty()
        when (val parsed = PairingPayload.parse(raw)) {
            is PairingPayload.Result.Err -> error = parsed.reason
            is PairingPayload.Result.Ok -> {
                url = parsed.parsed.url
                token = parsed.parsed.token
                error = null
                onSave(parsed.parsed.url, parsed.parsed.token) { failure ->
                    error = failure
                    if (failure == null) token = ""
                }
            }
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(SectionSpacing),
        ) {
            Section(
                title = "Scan pairing QR",
                supporting = "On the gateway host, open the WebUI Overview and scan the " +
                    "pairing QR. That fills the address and bearer token without typing.",
            ) {
                PrimaryButton(
                    text = "Scan QR code",
                    onClick = {
                        scanLauncher.launch(
                            android.content.Intent(context, QrPairingActivity::class.java),
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Section(
                title = "Gateway address",
                supporting = "A private LAN or Tailscale host may use http://. Anything " +
                    "reachable from the internet must use https://. Or scan the WebUI QR above.",
            ) {
                OutlinedTextField(
                    value = url,
                    onValueChange = {
                        url = it
                        error = null
                    },
                    label = { Text("Address") },
                    placeholder = { Text("http://homelabone.local:8765") },
                    singleLine = true,
                    isError = error != null,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Next,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = token,
                    onValueChange = {
                        token = it
                        error = null
                    },
                    label = { Text(if (settings.hasToken) "Replace bearer token" else "Bearer token") },
                    supportingText = {
                        Text(
                            if (settings.hasToken) {
                                "A token is stored, encrypted by the Android Keystore. " +
                                    "Leave blank to keep it."
                            } else {
                                "Printed by your gateway on first run at ~/.config/vocaphone/token."
                            }
                        )
                    },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Password,
                        imeAction = ImeAction.Done,
                    ),
                    // The keyboard's Done key saves, so finishing the token is not a
                    // dead end that leaves the user hunting for a button.
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier.fillMaxWidth(),
                )

                if (url.isNotBlank() && GatewayEndpoint.isCleartext(url.trim())) {
                    Text(
                        "This gateway is unencrypted. Your token and transcripts travel " +
                            "in the clear over this network — only use it on a network you trust.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                error?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }

                // Saving is confirmed by the footer, which reports the connection
                // test it kicks off rather than just that bytes hit the disk.
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PrimaryButton(
                        text = "Save",
                        onClick = submit,
                        enabled = url.isNotBlank() && (token.isNotBlank() || settings.hasToken),
                        modifier = Modifier.weight(1f),
                    )
                    SecondaryButton(
                        text = "Test connection",
                        onClick = onTest,
                        enabled = settings.isConfigured,
                        loading = testing,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            connection?.let { report ->
                Section(title = "Connection") {
                    StatusLine("Reachable", report.reachable)
                    StatusLine("Token accepted", report.tokenValid)
                    StatusLine("Engine ready", report.engineReady)
                    Text(
                        "Engine: ${report.engine.ifEmpty { "unknown" }}",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(
                        "Streaming: " + when (report.streamingSupported) {
                            true -> "supported by the active engine"
                            false -> "not supported — batch upload will be used"
                            null -> "not reported by this gateway"
                        },
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(report.message, style = MaterialTheme.typography.bodyMedium)
                }
            }

            if (settings.isConfigured) {
                TextButton(onClick = onClear) { Text("Remove gateway and delete stored token") }
            }
        }

        GatewayNextStepBar(
            configured = settings.isConfigured,
            inOnboarding = inOnboarding,
            testing = testing,
            connection = connection,
            onDone = onDone,
        )
    }
}

/** What the footer says, so the wording and its icon cannot drift apart. */
private enum class NextStep { PENDING, CHECKING, WARNING, READY }

/**
 * Pinned below the form so this screen always states what happens next. Saving a
 * token used to leave the user on a page whose only exit was the system back
 * gesture, with nothing on screen saying setup was waiting behind it.
 */
@Composable
private fun GatewayNextStepBar(
    configured: Boolean,
    inOnboarding: Boolean,
    testing: Boolean,
    connection: ConnectionReport?,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val step = when {
        !configured -> NextStep.PENDING
        testing -> NextStep.CHECKING
        connection == null -> NextStep.READY
        !connection.reachable || !connection.tokenValid -> NextStep.WARNING
        !connection.engineReady -> NextStep.WARNING
        else -> NextStep.READY
    }
    val hint = when {
        !configured && inOnboarding -> "Nothing saved yet — setup is waiting behind this screen."
        !configured -> "Nothing saved yet."
        testing -> "Checking your gateway…"
        connection == null -> "Address and token saved on this device."
        !connection.reachable || !connection.tokenValid -> connection.message
        !connection.engineReady -> "Connected. Load a model on the gateway when you get a chance."
        else -> "Connected and ready."
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shadowElevation = 12.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                NextStepIndicator(step)
                Text(
                    hint,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (step == NextStep.WARNING) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.weight(1f),
                )
            }
            if (configured) {
                PrimaryButton(
                    text = if (inOnboarding) "Continue setup" else "Done",
                    onClick = onDone,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                SecondaryButton(
                    text = if (inOnboarding) "Back to setup" else "Back",
                    onClick = onDone,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun NextStepIndicator(step: NextStep, modifier: Modifier = Modifier) {
    if (step == NextStep.CHECKING) {
        CircularProgressIndicator(
            modifier = modifier.size(20.dp),
            strokeWidth = 2.dp,
        )
        return
    }
    val (icon, tint) = when (step) {
        NextStep.READY -> R.drawable.ic_step_done to MaterialTheme.colorScheme.primary
        NextStep.WARNING -> R.drawable.ic_warning to MaterialTheme.colorScheme.error
        else -> R.drawable.ic_step_pending to MaterialTheme.colorScheme.outline
    }
    Icon(
        painter = painterResource(icon),
        contentDescription = null,
        tint = tint,
        modifier = modifier.size(20.dp),
    )
}

@Composable
private fun StatusLine(label: String, satisfied: Boolean) {
    Text(
        text = "${if (satisfied) "✓" else "✗"}  $label",
        style = MaterialTheme.typography.bodyMedium,
        color = if (satisfied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
    )
}
