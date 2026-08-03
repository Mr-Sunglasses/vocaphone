package io.github.mrsunglasses.localflow.ui

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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.github.mrsunglasses.localflow.core.GatewayEndpoint
import io.github.mrsunglasses.localflow.core.PairingPayload
import io.github.mrsunglasses.localflow.settings.LocalFlowSettings

@Composable
fun GatewayScreen(
    settings: LocalFlowSettings,
    connection: ConnectionReport?,
    testing: Boolean,
    onSave: (String, String, (String?) -> Unit) -> Unit,
    onTest: () -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var url by remember(settings.gatewayUrl) { mutableStateOf(settings.gatewayUrl) }
    var token by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }

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
                saved = false
                onSave(parsed.parsed.url, parsed.parsed.token) { failure ->
                    error = failure
                    saved = failure == null
                    if (failure == null) token = ""
                }
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SectionCard(
            title = "Scan pairing QR",
            supporting = "On the gateway host, open the WebUI Overview and scan the " +
                "pairing QR. That fills the address and bearer token without typing.",
        ) {
            Button(
                onClick = {
                    scanLauncher.launch(
                        android.content.Intent(context, QrPairingActivity::class.java),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Scan QR code")
            }
        }

        SectionCard(
            title = "Gateway address",
            supporting = "A private LAN or Tailscale host may use http://. Anything " +
                "reachable from the internet must use https://. Or scan the WebUI QR above.",
        ) {
            OutlinedTextField(
                value = url,
                onValueChange = {
                    url = it
                    error = null
                    saved = false
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
                    saved = false
                },
                label = { Text(if (settings.hasToken) "Replace bearer token" else "Bearer token") },
                supportingText = {
                    Text(
                        if (settings.hasToken) {
                            "A token is stored, encrypted by the Android Keystore. " +
                                "Leave blank to keep it."
                        } else {
                            "Printed by your gateway on first run at ~/.config/localflow/token."
                        }
                    )
                },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
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
            if (saved) {
                Text(
                    "Saved.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        onSave(url, token) { failure ->
                            error = failure
                            saved = failure == null
                            if (failure == null) token = ""
                        }
                    },
                    enabled = url.isNotBlank() && (token.isNotBlank() || settings.hasToken),
                ) {
                    Text("Save")
                }
                OutlinedButton(onClick = onTest, enabled = settings.isConfigured && !testing) {
                    if (testing) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text("Test connection")
                    }
                }
            }
        }

        connection?.let { report ->
            SectionCard(title = "Connection") {
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
}

@Composable
private fun StatusLine(label: String, satisfied: Boolean) {
    Text(
        text = "${if (satisfied) "✓" else "✗"}  $label",
        style = MaterialTheme.typography.bodyMedium,
        color = if (satisfied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
    )
}
