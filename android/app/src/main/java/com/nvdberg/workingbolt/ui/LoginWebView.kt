package com.nvdberg.workingbolt.ui

import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nvdberg.workingbolt.data.LBWebSource

/**
 * Shows the shared Lightning Bolt web view — the same instance the harvester drives, so the session the
 * user signs into is the one we read from. The counterpart of `LoginWebView` (UIViewRepresentable) on iOS.
 */
@Composable
fun LoginWebView(source: LBWebSource, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { source.webView },
        onRelease = { view -> (view.parent as? ViewGroup)?.removeView(view) },
    )
}

/**
 * A separate web view for a Lightning Bolt accept link, sharing the app's cookie jar (CookieManager is
 * process-wide on Android) so there's no login bounce. The user still confirms the swap on Lightning
 * Bolt's own screen; the app never accepts for them.
 */
@Composable
fun AcceptWebView(url: String, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.databaseEnabled = true
                webViewClient = android.webkit.WebViewClient()
                loadUrl(url)
            }
        },
    )
}

/**
 * Opens a Lightning Bolt accept link INSIDE the app, so there's no external-browser login bounce
 * (which was dropping the shift and dumping the user on the dashboard).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AcceptSheet(url: String, onDone: () -> Unit) {
    Dialog(onDismissRequest = onDone, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = Theme.colors.bg) {
            Column(Modifier.fillMaxSize()) {
                TopAppBar(
                    title = { Text("Pick up shift") },
                    actions = { TextButton(onClick = onDone) { Text("Done") } },
                )
                AcceptWebView(url, Modifier.fillMaxSize())
            }
        }
    }
}
