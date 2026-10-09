package com.nvdberg.workingbolt

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nvdberg.workingbolt.data.LBCreds
import com.nvdberg.workingbolt.data.UpdateChecker
import com.nvdberg.workingbolt.ui.CalendarScreen
import com.nvdberg.workingbolt.ui.CrewScreen
import com.nvdberg.workingbolt.ui.LaunchScreen
import com.nvdberg.workingbolt.ui.LoginWebView
import com.nvdberg.workingbolt.ui.PoolScreen
import com.nvdberg.workingbolt.ui.Prefs
import com.nvdberg.workingbolt.ui.SettingsScreen
import com.nvdberg.workingbolt.ui.Theme
import com.nvdberg.workingbolt.ui.WhoScreen
import com.nvdberg.workingbolt.ui.WorkingBoltTheme
import com.nvdberg.workingbolt.ui.fixedSp
import kotlinx.coroutines.launch

// A FragmentActivity because the system fingerprint / face prompt (androidx.biometric) needs one to attach to.
class MainActivity : FragmentActivity() {
    private var bioPrompt: (suspend (String) -> Boolean)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // The view model has no window of its own → hand it the prompt for biometric auto sign-in.
        val vm = ViewModelProvider(this)[AppViewModel::class.java]
        val prompt: suspend (String) -> Boolean = { reason -> LBCreds.authenticate(this, reason) }
        bioPrompt = prompt
        vm.biometricPrompt = prompt
        setContent {
            WorkingBoltTheme {
                RootScreen(vm)
            }
        }
    }

    override fun onDestroy() {
        // Don't leave the (longer-lived) view model holding this activity.
        val vm = ViewModelProvider(this)[AppViewModel::class.java]
        if (vm.biometricPrompt === bioPrompt) vm.biometricPrompt = null
        bioPrompt = null
        super.onDestroy()
    }
}

@Composable
private fun RootScreen(vm: AppViewModel = viewModel()) {
    val c = Theme.colors
    val context = LocalContext.current
    val prefs = Prefs.get(context)
    val updateScope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(Unit) { vm.start() }

    // Foreground/background hooks — the counterpart of iOS's scenePhase observer.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    vm.onForeground()
                    updateScope.launch { UpdateChecker.check(context.applicationContext) }   // newer build published?
                }
                Lifecycle.Event.ON_STOP -> vm.onBackground()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var showSplash by remember { mutableStateOf(true) }

    Box(Modifier.fillMaxSize().background(c.bg)) {
        // The web view is always mounted. During the first full scan it stays VISIBLE (behind a translucent
        // scrim, not an opaque cover) so the WebView is never throttled and every read lands reliably.
        LoginWebView(vm.source, Modifier.fillMaxSize())

        when {
            vm.showLogin -> LoginOverlay(vm)
            vm.syncing && !vm.hasData -> FirstRunScrim()
            else -> {
                // Opaque cover once we have data.
                Box(Modifier.fillMaxSize().background(c.bg)) { MainTabs(vm, prefs) }
            }
        }

        // The branded opening moment, over everything, while login + first sync spin up underneath.
        if (showSplash) LaunchScreen { showSplash = false }
    }
}

@Composable
private fun LoginOverlay(vm: AppViewModel) {
    val c = Theme.colors
    Column(Modifier.fillMaxSize().safeDrawingPadding(), verticalArrangement = Arrangement.SpaceBetween) {
        Row(
            Modifier.fillMaxWidth().background(c.panel).padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Text("⚡ Sign in to your schedule", fontWeight = FontWeight.Bold, color = c.ink)
        }
        // No-login preview — for anyone curious before signing in.
        Column(
            Modifier.fillMaxWidth().background(c.panel).padding(horizontal = 24.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Button(onClick = { vm.enterDemo() }, modifier = Modifier.fillMaxWidth()) {
                Text("Explore with sample data", fontWeight = FontWeight.SemiBold)
            }
            Box(Modifier.height(6.dp))
            Text(
                "No login needed — a preview with example shifts.",
                fontSize = 12.sp, color = c.muted, textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun FirstRunScrim() {
    // Translucent → the web view underneath stays un-occluded and keeps loading.
    Column(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.42f)).safeDrawingPadding(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("⚡", fontSize = 42.sp)
        Box(Modifier.height(14.dp))
        CircularProgressIndicator(color = Color.White)
        Box(Modifier.height(14.dp))
        Text("Setting up — reading your roster…", color = Color.White, fontWeight = FontWeight.Bold)
        Text("Just this once; a few seconds.", color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp)
    }
}

private data class Tab(val label: String, val icon: ImageVector)

private val TABS = listOf(
    Tab("Pool", Icons.Filled.Bolt),
    Tab("My Shifts", Icons.Filled.CalendarMonth),
    Tab("Who's On", Icons.Filled.People),
    Tab("Crew", Icons.Filled.Groups),
    Tab("More", Icons.Filled.Settings),
)

@Composable
private fun MainTabs(vm: AppViewModel, prefs: Prefs) {
    val scope = rememberCoroutineScopeCompat()
    var myShiftsTick by remember { mutableIntStateOf(0) }   // bumped when My Shifts is tapped → re-center
    var whoTick by remember { mutableIntStateOf(0) }        // bumped when Who's On is tapped → re-center on today
    var didInitTab by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        if (didInitTab == 0) {
            didInitTab = 1
            if (prefs.defaultTab in 0..3) vm.selectedTab = prefs.defaultTab
        }
    }

    Scaffold(
        containerColor = Theme.colors.bg,
        bottomBar = {
            NavigationBar(containerColor = Theme.colors.panel) {
                val c = Theme.colors
                val itemColors = NavigationBarItemDefaults.colors(
                    selectedIconColor = c.accent,
                    selectedTextColor = c.accent,
                    unselectedIconColor = c.muted,
                    unselectedTextColor = c.muted,
                    indicatorColor = c.accent.copy(alpha = 0.16f),
                )
                TABS.forEachIndexed { i, tab ->
                    NavigationBarItem(
                        colors = itemColors,
                        selected = vm.selectedTab == i,
                        onClick = {
                            when (i) {
                                // Pool → latest; recover the token if the light fetch failed
                                0 -> scope.launch { if (!vm.refreshOpenShifts()) vm.refresh() }
                                1 -> myShiftsTick++
                                2 -> whoTick++
                            }
                            vm.selectedTab = i
                        },
                        icon = { Icon(tab.icon, contentDescription = tab.label) },
                        label = { Text(tab.label, fontSize = fixedSp(10f), maxLines = 1) },
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (UpdateChecker.updateAvailable && !UpdateChecker.bannerDismissed) UpdateBanner()
            Box(Modifier.fillMaxSize()) {
                when (vm.selectedTab) {
                    0 -> PoolScreen(vm, prefs)
                    1 -> CalendarScreen(vm, myShiftsTick)
                    2 -> WhoScreen(vm, prefs, whoTick)
                    3 -> CrewScreen(vm, prefs)
                    else -> SettingsScreen(vm, prefs)
                }
            }
        }
    }
}

/**
 * "A newer build is out" strip above the tabs — Update downloads and installs it in the app, ✕ hides it for
 * this session. If the in-app install fails, the button opens the download link instead.
 */
@Composable
private fun UpdateBanner() {
    val c = Theme.colors
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val phase = UpdateChecker.phase
    val busy = phase is UpdateChecker.Phase.Downloading || phase == UpdateChecker.Phase.Installing
    Row(
        Modifier.fillMaxWidth().background(c.accent.copy(alpha = 0.14f)).padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            when (phase) {
                is UpdateChecker.Phase.Downloading ->
                    if (phase.percent >= 0) "Downloading update… ${phase.percent}%" else "Downloading update…"
                UpdateChecker.Phase.Installing -> "Installing — the app closes; open it again"
                UpdateChecker.Phase.Failed -> "Couldn't update here"
                UpdateChecker.Phase.NeedsAllow -> "Switch on “Allow from this source”, come back, tap Update"
                UpdateChecker.Phase.Idle -> "Update available — build ${UpdateChecker.latestBuild}"
            },
            Modifier.weight(1f).padding(vertical = 12.dp), fontSize = 14.sp, color = c.accent, fontWeight = FontWeight.SemiBold,
        )
        if (!busy) {
            if (phase == UpdateChecker.Phase.Failed) {
                Text(
                    "Open download", Modifier.clickable { UpdateChecker.openDownload(context) }.padding(12.dp),
                    fontSize = 14.sp, color = c.accent, fontWeight = FontWeight.Bold,
                )
            } else {
                Text(
                    "Update",
                    Modifier.clickable { scope.launch { UpdateChecker.downloadAndInstall(context) } }.padding(12.dp),
                    fontSize = 14.sp, color = c.accent, fontWeight = FontWeight.Bold,
                )
            }
            Text(
                "✕", Modifier.clickable { UpdateChecker.bannerDismissed = true }.padding(12.dp),
                fontSize = 14.sp, color = c.muted,
            )
        }
    }
}

@Composable
private fun rememberCoroutineScopeCompat() = androidx.compose.runtime.rememberCoroutineScope()
