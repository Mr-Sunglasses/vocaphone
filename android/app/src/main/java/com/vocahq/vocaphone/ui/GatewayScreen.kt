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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
    var confirmingRemove by remember { mutableStateOf(false) }

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

    val dirty = url.trim() != settings.gatewayUrl || token.isNotBlank()
    val canSave = url.isNotBlank() && (token.isNotBlank() || settings.hasToken)

    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .widthIn(max = AppContentMaxWidth)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(GroupSpacing),
        ) {
            if (settings.isConfigured) {
                GatewayStatusGroup(
                    testing = testing,
                    connection = connection,
                    onTest = onTest,
                )
            }

            SettingsGroup(
                title = "Address",
                footer = "Scan the QR code on your gateway's page to fill in both.",
            ) {
                SettingsGroupContent {
                    OutlinedTextField(
                        value = url,
                        onValueChange = {
                            url = it
                            error = null
                        },
                        label = { Text("Gateway address") },
                        placeholder = { Text("http://my-gateway.local:8765") },
                        singleLine = true,
                        isError = error != null,
                        trailingIcon = {
                            IconButton(
                                onClick = {
                                    scanLauncher.launch(
                                        android.content.Intent(context, QrPairingActivity::class.java),
                                    )
                                },
                            ) {
                                Icon(
                                    painterResource(R.drawable.ic_qr_scan),
                                    contentDescription = "Scan pairing QR code",
                                )
                            }
                        },
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
                        label = { Text(if (settings.hasToken) "Token (saved)" else "Token") },
                        supportingText = {
                            Text(
                                if (settings.hasToken) {
                                    "Leave blank to keep the saved token."
                                } else {
                                    "Your gateway prints it the first time it starts."
                                },
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
                        keyboardActions = KeyboardActions(onDone = { if (canSave) submit() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (url.isNotBlank() && GatewayEndpoint.isCleartext(url.trim())) {
                        Text(
                            "Unencrypted. Use it only on a network you trust.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    error?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                }
            }

            SettingsGroup {
                if (settings.isConfigured) {
                    SettingsActionRow(
                        title = "Open web dashboard",
                        external = true,
                        onClick = { context.openHttpUrl(settings.gatewayUrl) },
                    )
                    SettingsDivider()
                }
                SettingsActionRow(
                    title = "How to run a gateway",
                    external = true,
                    onClick = { context.openHttpUrl(GATEWAY_GUIDE_URL) },
                )
                if (settings.isConfigured) {
                    SettingsDivider()
                    SettingsActionRow(
                        title = "Remove gateway",
                        supporting = "Deletes the saved address and token.",
                        destructive = true,
                        onClick = { confirmingRemove = true },
                    )
                }
            }
        }

        // One primary action at a time: Save while there is something to
        // save, then the way back into setup. Outside setup the app bar's
        // back arrow is the way out, so no button is needed.
        val primary: Pair<String, () -> Unit>? = when {
            dirty -> "Save" to { submit() }
            inOnboarding && settings.isConfigured -> "Continue setup" to onDone
            else -> null
        }
        if (primary != null) {
            PrimaryButton(
                text = primary.first,
                onClick = primary.second,
                enabled = primary.first != "Save" || canSave,
                modifier = Modifier
                    .widthIn(max = AppContentMaxWidth)
                    .fillMaxWidth()
                    .padding(16.dp),
            )
        } else if (inOnboarding) {
            TextButton(onClick = onDone, modifier = Modifier.padding(16.dp)) {
                Text("Back to setup")
            }
        }
    }

    if (confirmingRemove) {
        AlertDialog(
            onDismissRequest = { confirmingRemove = false },
            title = { Text("Remove gateway?") },
            text = { Text("The address and token are deleted from this phone. Dictation needs a model on this phone or a gateway to work.") },
            confirmButton = {
                DestructiveTextButton(
                    text = "Remove",
                    onClick = {
                        confirmingRemove = false
                        onClear()
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmingRemove = false }) { Text("Cancel") }
            },
        )
    }
}

/** What the status row says, so the wording and its icon cannot drift apart. */
private enum class NextStep { CHECKING, WARNING, READY }

/**
 * Where the saved gateway stands, at the top of the page: one line with an
 * icon, the facts behind it, and the test that refreshes them. This used to be
 * a bar pinned over the bottom of the form.
 */
@Composable
private fun GatewayStatusGroup(
    testing: Boolean,
    connection: ConnectionReport?,
    onTest: () -> Unit,
) {
    val step = when {
        testing -> NextStep.CHECKING
        connection == null -> NextStep.READY
        !connection.reachable || !connection.tokenValid -> NextStep.WARNING
        !connection.engineReady -> NextStep.WARNING
        else -> NextStep.READY
    }
    val hint = when {
        testing -> "Checking your gateway…"
        connection == null -> "Saved on this phone."
        !connection.reachable || !connection.tokenValid -> connection.message
        !connection.engineReady -> "Connected. Load a model on the gateway when you get a chance."
        else -> "Connected and ready."
    }
    SettingsGroup(title = "Status") {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            NextStepIndicator(step)
            Text(
                hint,
                style = MaterialTheme.typography.bodyLarge,
                color = if (step == NextStep.WARNING) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                modifier = Modifier.weight(1f),
            )
        }
        if (connection != null && !testing) {
            SettingsDivider()
            Column(Modifier.padding(vertical = 8.dp)) {
                SettingsInfoRow("Engine", connection.engine.ifEmpty { "Unknown" })
                SettingsInfoRow(
                    "Live text",
                    when (connection.streamingSupported) {
                        true -> "Yes"
                        false -> "No, sent when you stop"
                        null -> "Not reported"
                    },
                )
            }
        }
        SettingsDivider()
        SettingsActionRow(
            title = if (testing) "Testing…" else "Test connection",
            enabled = !testing,
            onClick = onTest,
        )
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
        NextStep.WARNING -> R.drawable.ic_warning to MaterialTheme.colorScheme.error
        else -> R.drawable.ic_step_done to MaterialTheme.colorScheme.primary
    }
    Icon(
        painter = painterResource(icon),
        contentDescription = null,
        tint = tint,
        modifier = modifier.size(20.dp),
    )
}
