package com.example.localflow.android.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The gateway bearer token is encrypted with an AES-GCM key that never leaves
 * the Android Keystore; only the ciphertext and its nonce are written to
 * app-private storage.
 */
object TokenVault {

    /** Ciphertext and nonce, both base64, safe to persist and safe to log-redact. */
    data class SealedToken(val ciphertext: String, val nonce: String)

    private const val KEY_ALIAS = "localflow.gateway.token"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_LENGTH_BITS = 128
    private const val BASE64_FLAGS = Base64.NO_WRAP

    fun seal(token: String): SealedToken {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        return SealedToken(
            ciphertext = Base64.encodeToString(ciphertext, BASE64_FLAGS),
            nonce = Base64.encodeToString(cipher.iv, BASE64_FLAGS),
        )
    }

    /**
     * Returns null rather than throwing when the key has been invalidated — for
     * example after a device restore — so the caller can ask for the token again
     * instead of crashing mid-dictation.
     */
    fun open(sealed: SealedToken): String? = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val nonce = Base64.decode(sealed.nonce, BASE64_FLAGS)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_LENGTH_BITS, nonce))
        String(cipher.doFinal(Base64.decode(sealed.ciphertext, BASE64_FLAGS)), Charsets.UTF_8)
    }.getOrNull()

    fun clear() {
        runCatching { keyStore().deleteEntry(KEY_ALIAS) }
    }

    /** Never renders more than the shape of a token, so it can appear in the UI. */
    fun redact(token: String?): String = when {
        token.isNullOrEmpty() -> "Not set"
        token.length <= 8 -> "•".repeat(token.length)
        else -> "${token.take(4)}…${token.takeLast(4)} (${token.length} characters)"
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun secretKey(): SecretKey {
        val store = keyStore()
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // Dictation has to work from the bubble whenever the screen is on,
                // including straight after a reboot, so no user-authentication
                // requirement is attached to the key.
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }
}
