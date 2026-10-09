package com.nvdberg.workingbolt.data

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Checks whether a newer Android build has been published, by fetching a tiny public JSON
 * (`{"latestBuild": N, "url": "https://…"}`) and comparing to this build's versionCode — the Android
 * counterpart of UpdateChecker.swift. Read-only, best-effort: if the check fails (or the file isn't there)
 * nothing is shown, never a false "up to date". Powers the "Update available" banner above the tabs.
 *
 * There is no store on Android, so "Update" downloads the new APK and installs it over this one from inside
 * the app (same signing key — Android refuses anything else — so data and settings are kept). On Android 12+
 * an app may update itself without a further prompt; older phones show the system "Install?" once. Nothing
 * is ever downloaded or installed without the tap. If the in-app install fails, the banner falls back to
 * opening the download link in the browser.
 */
object UpdateChecker {
    // Its own file in the same public gist as the iOS feed — the iOS file (wb-version.json) is never touched.
    private const val FEED = "https://gist.githubusercontent.com/nvdberg/4424d5a739b37fb2969ec1bbbf2097b0/raw/wb-android.json"

    /** The latest build the feed reports (null until a successful check). */
    var latestBuild by mutableStateOf<Int?>(null)
        private set
    /** Where to download it (https only). */
    var downloadURL by mutableStateOf<String?>(null)
        private set
    /** User dismissed the banner this session. */
    var bannerDismissed by mutableStateOf(false)
    private var currentBuild = 0
    private var checking = false

    /** Where the in-app update is: nothing running, downloading (0–100, -1 = size unknown), installing, failed. */
    sealed interface Phase {
        data object Idle : Phase
        /** The phone's "Allow from this source" page was opened; Update is tapped again once it is on. */
        data object NeedsAllow : Phase
        data class Downloading(val percent: Int) : Phase
        data object Installing : Phase
        data object Failed : Phase
    }
    var phase by mutableStateOf<Phase>(Phase.Idle)
        internal set

    /** True only when we successfully learned of a strictly-newer build that has a download link. */
    val updateAvailable: Boolean
        get() = downloadURL != null && (latestBuild ?: 0) > currentBuild

    suspend fun check(context: Context) {
        if (checking) return
        checking = true
        try {
            if (currentBuild == 0) currentBuild = runCatching {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(context.packageName, 0).versionCode
            }.getOrDefault(0)
            if (currentBuild == 0) return
            val body = withContext(Dispatchers.IO) {
                var conn: HttpURLConnection? = null
                try {
                    conn = (URL(FEED).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 8_000
                        readTimeout = 8_000
                        useCaches = false
                    }
                    if (conn.responseCode == 200) conn.inputStream.bufferedReader().use { it.readText() } else null
                } catch (e: Exception) {
                    null
                } finally {
                    conn?.disconnect()
                }
            } ?: return
            val obj = runCatching { JSONObject(body) }.getOrNull() ?: return
            val n = obj.optInt("latestBuild", 0)
            if (n <= 0) return
            latestBuild = n
            downloadURL = obj.optString("url").takeIf { it.startsWith("https://") }
        } finally {
            checking = false
        }
    }

    /** Open the download in the browser. */
    fun openDownload(context: Context) {
        val url = downloadURL ?: return
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** Dropbox share links open a web page unless dl=1 — make them a direct download. */
    private fun directURL(url: String): String {
        val host = runCatching { Uri.parse(url).host }.getOrNull() ?: return url
        if (!host.endsWith("dropbox.com")) return url
        return when {
            "dl=0" in url -> url.replace("dl=0", "dl=1")
            "dl=1" in url -> url
            else -> url + (if ('?' in url) "&" else "?") + "dl=1"
        }
    }

    /**
     * Download the new APK and hand it to the system installer. Only ever called from the banner's Update tap.
     * The file must be this app (same package) and a strictly newer build, or it is discarded.
     */
    suspend fun downloadAndInstall(context: Context) {
        val url = downloadURL ?: return
        if (phase is Phase.Downloading || phase == Phase.Installing) return
        val app = context.applicationContext
        // Android asks once per app before it may install anything: open that switch, then they tap Update again.
        if (!app.packageManager.canRequestPackageInstalls()) {
            val opened = runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }.isSuccess
            phase = if (opened) Phase.NeedsAllow else Phase.Failed
            return
        }
        phase = Phase.Downloading(0)
        val apk = withContext(Dispatchers.IO) {
            var conn: HttpURLConnection? = null
            try {
                val dir = File(app.cacheDir, "update").apply { mkdirs() }
                val out = File(dir, "wb-update.apk")
                conn = (URL(directURL(url)).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15_000
                    readTimeout = 30_000
                    useCaches = false
                }
                if (conn.responseCode != 200) return@withContext null
                val total = conn.contentLengthLong
                conn.inputStream.use { input ->
                    out.outputStream().use { output ->
                        val buf = ByteArray(64 * 1024)
                        var done = 0L
                        var shown = -2
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            done += n
                            val pct = if (total > 0) (done * 100 / total).toInt() else -1
                            if (pct != shown) { shown = pct; phase = Phase.Downloading(pct) }
                        }
                    }
                }
                @Suppress("DEPRECATION")
                val info = app.packageManager.getPackageArchiveInfo(out.path, 0)
                @Suppress("DEPRECATION")
                if (info == null || info.packageName != app.packageName || info.versionCode <= currentBuild) {
                    out.delete()
                    null
                } else out
            } catch (e: Exception) {
                null
            } finally {
                conn?.disconnect()
            }
        }
        if (apk == null) { phase = Phase.Failed; return }
        phase = Phase.Installing
        val ok = withContext(Dispatchers.IO) {
            runCatching {
                val installer = app.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(app.packageName)
                    setSize(apk.length())
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                    }
                }
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    session.openWrite("wb", 0, apk.length()).use { sink ->
                        apk.inputStream().use { it.copyTo(sink) }
                        session.fsync(sink)
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                    val intent = Intent(app, UpdateReceiver::class.java).setPackage(app.packageName)
                    session.commit(PendingIntent.getBroadcast(app, id, intent, flags).intentSender)
                }
            }.isSuccess
        }
        if (!ok) phase = Phase.Failed
        // On success the system replaces the app (this process ends) — or UpdateReceiver hears otherwise.
    }
}

/** Hears back from the system installer: shows its "Install?" prompt when one is needed, or marks a failure. */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                val shown = confirm != null && runCatching {
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.isSuccess
                // The prompt can be cancelled; the banner goes back to "Update" so it can be tried again.
                UpdateChecker.phase = if (shown) UpdateChecker.Phase.Idle else UpdateChecker.Phase.Failed
            }
            // Success, or they backed out of the system prompt: back to "Update" so it can be tried again.
            PackageInstaller.STATUS_SUCCESS, PackageInstaller.STATUS_FAILURE_ABORTED ->
                UpdateChecker.phase = UpdateChecker.Phase.Idle
            else -> UpdateChecker.phase = UpdateChecker.Phase.Failed
        }
    }
}
