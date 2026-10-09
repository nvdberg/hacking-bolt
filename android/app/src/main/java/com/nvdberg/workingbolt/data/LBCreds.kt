package com.nvdberg.workingbolt.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CompletableDeferred
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Convenience (opt-in, off by default): keep the Lightning Bolt username + password on this device so the app
 * can sign back in when LB's session expires — the Android counterpart of LBCreds in BiometricLogin.swift.
 *
 * The pair is encrypted with an AES-GCM key that lives in the Android Keystore (never exportable) and the
 * ciphertext sits in the app's private preferences — excluded from backups, never transmitted anywhere.
 * Two modes, chosen by the caller: silent ("Keep me signed in") or behind a fingerprint / face check.
 */
object LBCreds {
    private const val ALIAS = "wb_lb_login"
    private const val FILE = "workingbolt_login"       // kept apart from the settings file; excluded from backup
    private const val SLOT = "lb"

    private fun sp(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    /** Is auto-login set up? (Cheap existence check — never prompts.) */
    fun isEnabled(context: Context): Boolean = sp(context).contains(SLOT)

    /** True only if this device can actually do a biometric check (fingerprint / face enrolled). */
    fun biometricsAvailable(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) ==
            BiometricManager.BIOMETRIC_SUCCESS

    /** Save (or replace) the credentials. Returns null on success, else an error message. */
    fun save(context: Context, username: String, password: String): String? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val ct = cipher.doFinal("$username\n$password".toByteArray(Charsets.UTF_8))
        val blob = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
        sp(context).edit().putString(SLOT, blob).apply()
        null
    } catch (e: Exception) {
        "Couldn't set up secure storage on this device."
    }

    /** Read the credentials (username, password), or null if nothing is stored / it can't be decrypted. */
    fun load(context: Context): Pair<String, String>? = try {
        val blob = sp(context).getString(SLOT, null)?.split(":")
        if (blob == null || blob.size != 2) null
        else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(blob[0], Base64.NO_WRAP)))
            }
            val parts = String(cipher.doFinal(Base64.decode(blob[1], Base64.NO_WRAP)), Charsets.UTF_8).split("\n", limit = 2)
            if (parts.size == 2) parts[0] to parts[1] else null
        }
    } catch (e: Exception) {
        null
    }

    /** Forget the stored credentials (turning auto-login off). */
    fun clear(context: Context) {
        sp(context).edit().remove(SLOT).apply()
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
    }

    /** Show the system fingerprint / face prompt; true only on a successful match. */
    suspend fun authenticate(activity: FragmentActivity, reason: String): Boolean {
        if (!biometricsAvailable(activity)) return false
        val done = CompletableDeferred<Boolean>()
        val prompt = BiometricPrompt(
            activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { done.complete(true) }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { done.complete(false) }
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Working-Bolt")
                .setSubtitle(reason)
                .setNegativeButtonText("Cancel")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
                .build()
        )
        return done.await()
    }
}
