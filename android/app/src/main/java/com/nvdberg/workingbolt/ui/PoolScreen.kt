package com.nvdberg.workingbolt.ui

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewModelScope
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MyPost
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.OpenShift
import com.nvdberg.workingbolt.model.RecentTake
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

private enum class PoolTab { All, ForMe, Mine }   // All posted shifts (default) / For me / My posts

/** The accept page to open — [swapSlot] is set when it's the first half of a swap someone sent me. */
private data class AcceptTarget(val url: String, val swapSlot: Int? = null)

/** Every open (offered) shift in the group, with a mini-calendar strip showing how each lands on my roster. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PoolScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    var tab by remember { mutableStateOf(if (prefs.poolForMe) PoolTab.ForMe else PoolTab.All) }
    val pool = vm.poolShifts                    // open posts + offers aimed at me (others' direct offers stay private)
    val forMe = pool.filter { vm.isPickable(it) }
    val showMine = vm.showMyPostsTab
    val posts = vm.myPosts
    val myPostsPending = posts.count { it.status == MyPost.Status.Pending }
    // Fall back to "All" if the My-posts segment vanished (posts cleared) while it was selected.
    val effectiveTab = if (tab == PoolTab.Mine && !showMine) PoolTab.All else tab
    val shown = if (effectiveTab == PoolTab.ForMe) forMe else pool

    // Full roster (2022 → next-year), same source the My Shifts calendar uses — so future months populate.
    val mySched = if (vm.shiftLog.isEmpty()) vm.myShifts else vm.shiftLog
    val today = AppViewModel.todayRegina()

    // Mini-calendar data, computed once per data change (not per render).
    val openDates = vm.openForAllDates
    val mondayFirst = prefs.weekStart == 1      // 0 = Sunday, 1 = Monday (mini-calendars)
    val monthMaps = remember(pool, openDates, mySched, today, mondayFirst) {
        computeCalMonths(pool, mySched, today).map { key -> computeMonthMap(key, mySched, openDates, today, mondayFirst) }
    }

    var acceptTarget by remember { mutableStateOf<OpenShift?>(null) }   // confirm dialog
    // The accept sheet lives HERE, not on the row: a pool refresh drops a just-taken shift's row, which would
    // tear the sheet (and its "no longer available" banner) down mid-read.
    var accepting by remember { mutableStateOf<AcceptTarget?>(null) }
    var swapMsg by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { vm.loadHistory() }       // backfill the full roster so the mini-calendar shows future months
    LaunchedEffect(Unit) { vm.loadPickups() }       // My Posts → "picked up" (shared backend)
    LaunchedEffect(Unit) { vm.loadMyPostNotes() }   // label pending posts as swaps (their notes)
    LaunchedEffect(Unit) { vm.loadSwapNotes() }     // pair the halves of two-way swaps (Swaps card)

    val showTabs = pool.isNotEmpty() || showMine
    val showSwaps = vm.incomingSwaps.isNotEmpty() || vm.swapReturnsForMe.isNotEmpty() ||
        vm.declinedSwaps.isNotEmpty() || swapMsg != null

    val listState = rememberLazyListState()
    // Arriving from a My Shifts calendar tap: show all shifts, then scroll to the open shift on that date.
    LaunchedEffect(vm.poolJumpDate, shown.size) {
        val date = vm.poolJumpDate ?: return@LaunchedEffect
        tab = PoolTab.All                                    // ensure it's visible (not filtered out)
        val idx = pool.indexOfFirst { it.iso == date }
        if (idx >= 0) listState.animateScrollToItem(idx + (if (showTabs) 1 else 0) + (if (showSwaps) 1 else 0))
        vm.poolJumpDate = null                               // consume the signal
    }

    val pull = rememberPullToRefreshState()
    if (pull.isRefreshing) {
        LaunchedEffect(Unit) {
            try { vm.refresh(); vm.loadRecentlyTaken() } finally { pull.endRefresh() }
        }
    }

    Column(Modifier.fillMaxSize().background(c.bg)) {
        Text(
            "Shift Pool",
            fontSize = 16.sp, color = c.ink,
            modifier = Modifier.padding(start = 14.dp, top = 8.dp),
        )
        if (!vm.loggedIn && vm.hasData && !vm.demo) {
            Row(
                Modifier.fillMaxWidth()
                    .background(c.accent.copy(alpha = 0.10f))
                    .clickable { vm.signIn() }
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Showing saved shifts — tap to sign in and update",
                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
                )
            }
        }

        if (monthMaps.isNotEmpty()) {
            Row(
                Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                monthMaps.forEach { m ->
                    MiniMonth(m.y, m.mo, m.fill, m.post, m.open, m.today, m.fuseStart, m.fuseEnd)
                }
            }
            PoolLegend(mySched.map { it.unit } + pool.map { it.unit }, posted = vm.postedPendingDates.isNotEmpty())
            HorizontalDivider(color = c.line)
        }

        Box(Modifier.fillMaxSize().clipToBounds().nestedScroll(pull.nestedScrollConnection)) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (showTabs) {
                    item(key = "tabs") {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(
                                Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                val chipColors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = c.accent.copy(alpha = 0.16f),
                                    selectedLabelColor = c.accent,
                                    labelColor = c.muted,
                                )
                                FilterChip(
                                    selected = effectiveTab == PoolTab.All,
                                    onClick = { tab = PoolTab.All },
                                    colors = chipColors,
                                    label = { Text("All ${pool.size}") },
                                )
                                FilterChip(
                                    selected = effectiveTab == PoolTab.ForMe,
                                    onClick = { tab = PoolTab.ForMe },
                                    colors = chipColors,
                                    label = { Text("For me ${forMe.size}") },
                                )
                                if (showMine) {
                                    FilterChip(
                                        selected = effectiveTab == PoolTab.Mine,
                                        onClick = { tab = PoolTab.Mine },
                                        colors = chipColors,
                                        label = { Text(if (myPostsPending > 0) "My posts $myPostsPending" else "My posts") },
                                    )
                                }
                            }
                            vm.lastUpdated?.let { t ->
                                Column(horizontalAlignment = Alignment.End) {
                                    Text("Updated", fontSize = 9.sp, color = c.muted)
                                    Text(poolUpdatedLabel(t), fontSize = 11.sp, color = c.muted)
                                }
                            }
                        }
                    }
                }
                if (showSwaps) {
                    item(key = "swaps") {
                        SwapCards(vm, swapMsg, onMsg = { swapMsg = it }, onAccept = { accepting = it })
                    }
                }
                if (effectiveTab == PoolTab.Mine) {
                    item(key = "mine") { MyPostsList(vm, posts) }
                } else {
                    items(shown, key = { it.id }) { s ->
                        OpenShiftCard(s, busy = vm.busyNote(s.iso)) { if (!s.conflict && s.acceptURL != null) acceptTarget = s }
                    }
                    if (shown.isEmpty() && !vm.loading) {
                        item(key = "empty") {
                            Text(
                                if (effectiveTab == PoolTab.ForMe) "Nothing open for you to pick up right now."
                                else "No open shifts right now. 🎉",
                                color = c.muted,
                                modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                    val taken = if (effectiveTab == PoolTab.ForMe) vm.recentlyTakenForMe else vm.recentlyTaken
                    if (taken.isNotEmpty()) {
                        item(key = "taken") {
                            RecentlyTakenList(taken, forMe = effectiveTab == PoolTab.ForMe, prefs = prefs)
                        }
                    }
                }
            }
            if (pull.isRefreshing || pull.progress > 0f) {
                PullToRefreshContainer(state = pull, modifier = Modifier.align(Alignment.TopCenter))
            }
            if (vm.loading && !vm.hasData) {
                Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = c.accent)
                    Spacer(Modifier.height(10.dp))
                    Text("Reading your roster…", color = c.muted)
                }
            }
        }
    }

    // Guard against an accidental tap opening the accept flow. A day I marked busy / asked off is still
    // takeable — with a reminder first.
    acceptTarget?.let { s ->
        val info = Units.info[s.unit]
        val busy = vm.busyNote(s.iso)
        AlertDialog(
            onDismissRequest = { acceptTarget = null },
            title = { Text(if (busy == null) "Pick up this shift?" else "You marked ${fmt(s.iso, "MMM d")} busy") },
            text = {
                Text(
                    (busy?.let { "$it\n\n" } ?: "") +
                        "${info?.full ?: s.unit.name} · ${fmt(s.iso, "EEE, MMM d, yyyy")} · ${s.hoursLabel}\n" +
                        "Offered by ${s.offerer}. You'll still confirm on the scheduler's own screen.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    s.acceptURL?.let { accepting = AcceptTarget(it) }
                    acceptTarget = null
                }) { Text(if (busy == null) "Continue" else "Take it anyway") }
            },
            dismissButton = { TextButton(onClick = { acceptTarget = null }) { Text("Cancel") } },
        )
    }

    accepting?.let { t ->
        PoolAcceptSheet(vm, t.url) {
            if (accepting != null) {
                accepting = null
                // On the view model's scope, so these finish even if the Pool tab is left meanwhile.
                // Reconcile the pool after any attempt — a taken/withdrawn shift drops off right away.
                vm.viewModelScope.launch { vm.afterAcceptAttempt(t.url) }
                // An incoming swap's accept page just closed: if I now hold their shift, send mine back (the
                // "Accept swap" confirmation covered both halves).
                t.swapSlot?.let { slot ->
                    vm.viewModelScope.launch {
                        swapMsg = "Checking the swap…"
                        val out = vm.finishIncomingSwap(slot)
                        swapMsg = when {
                            out == null -> null
                            out.ok -> "✅ Swap done on your side — your shift went back to them."
                            else -> out.message ?: "Couldn't send your shift back — tap Send it back below."
                        }
                    }
                }
            }
        }
    }
}

// Show the time for a same-day update, but include the date when it's older — so a stale snapshot
// (e.g. last night's) reads as stale instead of looking current.
private fun poolUpdatedLabel(millis: Long): String {
    val t = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault())
    val sameDay = t.toLocalDate() == LocalDate.now()
    return t.format(DateTimeFormatter.ofPattern(if (sameDay) "HH:mm" else "MMM d, HH:mm", Locale.US))
}

/** Two-way swaps that need me: offers to swap with me, my half still to send back, and returns of my own swaps. */
@Composable
private fun SwapCards(vm: AppViewModel, swapMsg: String?, onMsg: (String?) -> Unit, onAccept: (AcceptTarget) -> Unit) {
    val c = Theme.colors
    val incoming = vm.incomingSwaps
    val returns = vm.swapReturnsForMe
    val declined = vm.declinedSwaps
    var confirm by remember { mutableStateOf<AppViewModel.IncomingSwap?>(null) }
    var busy by remember { mutableStateOf(false) }

    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(c.accent.copy(alpha = 0.08f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.SwapHoriz, contentDescription = null, tint = c.ink, modifier = Modifier.size(18.dp))
            Text("Swaps", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
        }
        returns.forEach { o ->
            SwapRow(
                title = "${o.offerer} sent their ${Units.short(o.unit)} on ${swapPretty(o.iso)} back",
                detail = "The return half of your swap. Take it to finish.",
                button = "Take it", enabled = !busy,
            ) { o.acceptURL?.let { onAccept(AcceptTarget(it)) } }
        }
        incoming.forEach { s ->
            if (s.taken) {
                SwapRow(
                    title = "You took ${s.from}'s ${Units.short(s.theirsUnit)} on ${swapPretty(s.theirsDate)}",
                    detail = "Your ${Units.short(s.mine.unit)} on ${swapPretty(s.mine.date)} still has to go back to finish the swap.",
                    button = "Send it back", enabled = !busy,
                ) {
                    busy = true
                    // On the view model's scope: a half-sent return must not be cut off by leaving the tab.
                    vm.viewModelScope.launch {
                        val out = vm.sendSwapBack(s)
                        busy = false
                        onMsg(
                            if (out.ok) "✅ Sent your ${Units.short(s.mine.unit)} on ${swapPretty(s.mine.date)} back to ${s.from}."
                            else out.message ?: "Couldn't send it — pull to refresh and try again."
                        )
                    }
                }
            } else {
                SwapRow(
                    title = "${s.from} wants to swap",
                    detail = "You take their ${Units.short(s.theirsUnit)} on ${swapPretty(s.theirsDate)}; " +
                        "your ${Units.short(s.mine.unit)} on ${swapPretty(s.mine.date)} goes to them.",
                    button = "Accept swap", enabled = !busy,
                ) { confirm = s }
            }
        }
        declined.forEach { d ->
            SwapRow(
                title = "Swap with ${d.to} didn't go through",
                detail = "It was declined or cancelled. Your ${Units.short(d.mine.unit)} on ${swapPretty(d.mine.date)} is still yours.",
                button = "OK", enabled = !busy,
            ) { vm.dismissDeclinedSwap(d.slot) }
        }
        swapMsg?.let { Text(it, fontSize = 12.sp, color = c.muted) }
    }

    confirm?.let { s ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Accept this swap?") },
            text = {
                Text(
                    "Lightning Bolt opens to take ${s.from}'s ${Units.short(s.theirsUnit)} on ${swapPretty(s.theirsDate)}. " +
                        "Once it's yours, Working-Bolt sends your ${Units.short(s.mine.unit)} on ${swapPretty(s.mine.date)} back to ${s.from}.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    s.acceptURL?.let { onAccept(AcceptTarget(it, swapSlot = s.slot)) }
                    confirm = null
                }) { Text("Accept swap") }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Not now") } },
        )
    }
}

@Composable
private fun SwapRow(title: String, detail: String, button: String, enabled: Boolean, action: () -> Unit) {
    val c = Theme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
            Text(detail, fontSize = 12.sp, color = c.muted)
        }
        Button(
            onClick = action, enabled = enabled,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            colors = ButtonDefaults.buttonColors(containerColor = c.accent),
        ) { Text(button, fontSize = 13.sp) }
    }
}

/** The units actually present in the current data — keeps the key short and relevant. */
@Composable
private fun PoolLegend(units: List<UnitKey>, posted: Boolean) {
    val c = Theme.colors
    val present = units.distinct().sortedBy { it.name }
    Row(
        Modifier.horizontalScroll(rememberScrollState())
            .padding(start = 14.dp, end = 14.dp, top = 5.dp, bottom = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        present.forEach { u ->
            val info = Units.info[u] ?: return@forEach
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(info.color))
                Text(info.short, fontSize = 9.5.sp, color = c.muted, maxLines = 1)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.size(7.dp).border(1.5.dp, c.available, CircleShape))
            Text("Open", fontSize = 9.5.sp, color = c.muted)
        }
        if (posted) {                                        // a shift I've posted, still waiting (My Shifts marker)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(7.dp).clip(RoundedCornerShape(2.dp)).background(poolPostedColor()))
                Text("Posted", fontSize = 9.5.sp, color = c.muted)
            }
        }
    }
}

@Composable
private fun OpenShiftCard(shift: OpenShift, busy: String? = null, onTap: () -> Unit) {
    val c = Theme.colors
    val info = Units.info[shift.unit]
    val color = info?.color ?: Color.Gray
    val free = !shift.conflict

    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(if (free) c.panel else color.copy(alpha = 0.13f))
            .clickable(enabled = free) { onTap() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(5.dp).height(84.dp).background(color))
        Column(
            Modifier.width(46.dp).padding(start = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(fmt(shift.iso, "EEE"), fontSize = 11.sp, color = c.muted)
            Text(
                fmt(shift.iso, "d"), fontSize = 20.sp, fontWeight = FontWeight.ExtraBold,
                color = if (free) color else c.muted,
            )
            Text(fmt(shift.iso, "MMM").uppercase(), fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = c.muted)
        }
        Column(
            Modifier.weight(1f).padding(vertical = 12.dp, horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    info?.short ?: shift.unit.name,
                    fontSize = 11.sp, fontWeight = FontWeight.Bold, color = color,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(color.copy(alpha = 0.16f))
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                )
                Text(info?.full ?: "", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.ink, maxLines = 1)
                if (shift.isSplit) {
                    Text(
                        "SPLIT", fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, color = c.muted,
                        modifier = Modifier.clip(RoundedCornerShape(50)).background(c.line)
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
            }
            Text(shift.hoursLabel, fontSize = 12.sp, color = c.muted)
            Text("Offered by ${shift.offerer}", fontSize = 12.sp, color = c.muted)
        }
        Box(Modifier.width(108.dp).padding(end = 12.dp), contentAlignment = Alignment.CenterEnd) {
            if (free && busy != null) {               // a day I marked busy / asked off — still takeable, with a reminder
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text("You're busy", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.muted)
                    Text(busy, fontSize = 11.sp, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            } else if (free) {
                Text("Available ↗", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.available)
            } else {
                Text(shift.flag, fontSize = 11.sp, color = c.muted, textAlign = TextAlign.End)
            }
        }
    }
}

/**
 * Brian's ask: shifts that just left the pool because someone took them — folded away by default, no names.
 * Proof the pool is live: a shift that vanished was taken, not lost.
 */
@Composable
private fun RecentlyTakenList(items: List<RecentTake>, forMe: Boolean, prefs: Prefs) {
    val c = Theme.colors
    var open by remember { mutableStateOf(false) }

    if (!prefs.showRecentTaken) {          // eye: hidden away (back via the eye, or More → Advanced)
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            Row(
                Modifier.clickable { prefs.updateShowRecentTaken(true) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Outlined.Visibility, contentDescription = null, tint = c.muted, modifier = Modifier.size(13.dp))
                Text("Show recently taken", fontSize = 11.sp, color = c.muted)
            }
        }
        return
    }

    Column(
        Modifier.fillMaxWidth().padding(top = 6.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(c.panel)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                Modifier.weight(1f).clickable { open = !open },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = c.muted, modifier = Modifier.size(18.dp))
                Text(
                    "Recently taken (${items.size})",
                    fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null, tint = c.muted, modifier = Modifier.size(18.dp),
                )
            }
            Icon(
                Icons.Outlined.VisibilityOff, contentDescription = "Hide recently taken", tint = c.muted,
                modifier = Modifier.padding(start = 8.dp).size(18.dp).clickable { prefs.updateShowRecentTaken(false) },
            )
        }
        if (open) {
            items.forEach { t ->
                val info = Units.info[t.unit]
                val color = info?.color ?: Color.Gray
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (t.unit == UnitKey.MSU || t.unit == UnitKey.PRR) "Pasqua" else info?.short ?: t.unit.name,
                        fontSize = 11.sp, fontWeight = FontWeight.Bold, color = color,
                        modifier = Modifier.clip(RoundedCornerShape(50))
                            .background(color.copy(alpha = 0.16f))
                            .padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                    Text(fmt(t.iso, "EEE, MMM d"), fontSize = 12.sp, color = c.ink, modifier = Modifier.weight(1f))
                    Text("taken ${takenAgo(t.whenMillis)}", fontSize = 11.sp, color = c.muted)
                }
            }
            Text(
                if (forMe) "Last 2 days — only ones you could have picked up."
                else "Last 2 days. Your own pickups show in My Shifts once LB has them.",
                fontSize = 11.sp, color = c.muted,
            )
        }
    }
}

private fun takenAgo(whenMillis: Long): String {
    val m = maxOf(0L, (System.currentTimeMillis() - whenMillis) / 60_000)
    if (m < 60) return if (m < 2) "just now" else "$m min ago"
    val h = m / 60
    return if (h < 24) "$h h ago" else "yesterday"
}

// ── accept page ──────────────────────────────────────────────────────────────

/**
 * Opens a Lightning Bolt accept link INSIDE the app, in a web view that shares the app's already-signed-in
 * session (CookieManager is process-wide on Android) — so there's no external-browser login bounce. The user
 * still confirms on Lightning Bolt's own screen; the app never accepts for them. [onDone] runs when it closes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PoolAcceptSheet(vm: AppViewModel, url: String, onDone: () -> Unit) {
    val c = Theme.colors
    val context = LocalContext.current
    var gone by remember { mutableStateOf(false) }      // LB reported the offer no longer exists (withdrawn / taken)
    val web = remember(url) {
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            webViewClient = WebViewClient()
            loadUrl(url)                                 // cold-load dashboard/#/swop/<id>/accept → openSwop fires on boot
        }
    }

    // Poll the page: surface LB's "Preswap no longer exists" as a friendly banner; once the Accept/Decline modal
    // is up we keep watching (the error only appears AFTER Submit); if we get stuck on the plain dashboard
    // (session had expired and login stripped the swop hash), re-load the accept URL once now that we're signed
    // in. Waits through a manual re-login too.
    LaunchedEffect(web) {
        var reloaded = false
        var dashHits = 0
        delay(600)
        repeat(200) {                                    // ~100s: covers the read-modal-then-Submit window
            val state = suspendCancellableCoroutine<String> { cont ->
                web.evaluateJavascript(ACCEPT_STATE_JS) { r -> if (cont.isActive) cont.resume(r ?: "") }
            }
            when {
                state.contains("gone") -> {              // LB: offer already withdrawn/taken
                    // LB's own accept page threw "Preswap no longer exists" — swap its scary red error for a
                    // calm explanation and refresh the pool so the dead row disappears.
                    gone = true
                    vm.viewModelScope.launch { vm.refreshOpenShifts() }
                    return@LaunchedEffect                // stop — the sheet now shows the banner
                }
                state.contains("dash") -> {
                    dashHits++
                    if (dashHits >= 4 && !reloaded) {    // stuck ~2s → login stripped the swop, retry once
                        reloaded = true; dashHits = 0
                        web.loadUrl(url)
                    }
                }
                else -> dashHits = 0                     // accept modal / login / loading → keep watching
            }
            delay(500)
        }
    }

    Dialog(onDismissRequest = onDone, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = c.bg) {
            Column(Modifier.fillMaxSize()) {
                TopAppBar(
                    title = { Text("Pick up shift") },
                    actions = { TextButton(onClick = onDone) { Text("Done") } },
                )
                Box(Modifier.fillMaxSize()) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { web },
                        onRelease = { it.stopLoading(); it.destroy() },
                    )
                    if (gone) {
                        Column(
                            Modifier.fillMaxSize().background(c.bg).padding(horizontal = 32.dp),
                            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Icon(Icons.Outlined.History, contentDescription = null, tint = c.accent, modifier = Modifier.size(46.dp))
                            Text("Shift no longer available", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink)
                            Text(
                                "This one was just withdrawn or picked up by someone else. Nothing changed on your " +
                                    "schedule — the pool's been refreshed.",
                                fontSize = 15.sp, color = c.muted, textAlign = TextAlign.Center,
                            )
                            Button(
                                onClick = onDone,
                                shape = RoundedCornerShape(50),
                                colors = ButtonDefaults.buttonColors(containerColor = c.accent),
                                contentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp),
                            ) { Text("Back to pool", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
                        }
                    }
                }
            }
        }
    }
}

private const val ACCEPT_STATE_JS = """
(function(){ var t = (document.body && document.body.innerText) || '';
  if (/no longer exists|REQUEST HAD ERRORS/i.test(t)) return 'gone';
  if (/OPENING SWAPORTUNITY|SUBMIT/i.test(t)) return 'accept';
  if (/Sign in to access|Forgot your password/i.test(t)) return 'login';
  if (/NEXT 3 DAYS|SWAPORTUNITY FEED/i.test(t)) return 'dash';
  return 'wait'; })();
"""

// ── mini-calendar model ──────────────────────────────────────────────────────

data class MonthMap(
    val y: Int, val mo: Int,
    val fill: Map<Int, Color>, val post: Map<Int, Color>, val open: Set<Int>,
    val today: Int?, val fuseStart: Set<Int>, val fuseEnd: Set<Int>,
)

/** Continuous "YYYY-MM" months from the current month through the last month with an open shift. */
private fun computeCalMonths(open: List<OpenShift>, mine: List<MyShift>, today: String): List<String> {
    val cur = today.take(7)
    val all = open.map { it.iso.take(7) } + mine.map { it.date.take(7) }
    val hi = all.maxOrNull() ?: cur
    val out = ArrayList<String>()
    var (y, m) = ym(minOf(cur, hi))
    val (ey, em) = ym(maxOf(cur, hi))
    var guard = 0
    while ((y < ey || (y == ey && m <= em)) && guard < 24) {
        out.add(String.format(Locale.ROOT, "%04d-%02d", y, m))
        m++; if (m > 12) { m = 1; y++ }
        guard++
    }
    return out
}

private fun ym(key: String): Pair<Int, Int> {
    val p = key.split("-").mapNotNull { it.toIntOrNull() }
    return (p.getOrNull(0) ?: 2026) to (p.getOrNull(1) ?: 1)
}

private fun computeMonthMap(key: String, mine: List<MyShift>, openDates: Set<String>, today: String, mondayFirst: Boolean): MonthMap {
    val (y, mo) = ym(key)
    val fill = HashMap<Int, Color>()
    val post = HashMap<Int, Color>()
    val openDays = HashSet<Int>()
    val fuseStart = HashSet<Int>()
    val fuseEnd = HashSet<Int>()
    fun day(iso: String) = iso.takeLast(2).toIntOrNull()

    for (s in mine) if (s.date.startsWith(key)) day(s.date)?.let { d -> fill[d] = Units.color(s.unit) }
    for (s in mine) {
        if (!s.overnight) continue
        val nd = ConflictEngine.addDay(s.date)
        if (nd.startsWith(key)) day(nd)?.let { d -> post[d] = Units.color(s.unit) }
        // fuse the on-call day into its post-call next day, unless the call is the last column of a week row
        if (s.date.startsWith(key) && nd.startsWith(key)) {
            val cd = day(s.date); val nday = day(nd)
            if (cd != null && nday != null) {
                val wd = LocalDate.of(y, mo, cd).dayOfWeek.value % 7   // 0 = Sunday
                val wcol = if (mondayFirst) (wd + 6) % 7 else wd
                if (wcol < 6) { fuseStart.add(cd); fuseEnd.add(nday) }
            }
        }
    }
    // only shifts genuinely open to all — a swap / direct offer or my own post is not marked open
    for (iso in openDates) if (iso.startsWith(key)) day(iso)?.let { openDays.add(it) }
    return MonthMap(
        y = y, mo = mo, fill = fill, post = post, open = openDays,
        today = if (today.startsWith(key)) day(today) else null,
        fuseStart = fuseStart, fuseEnd = fuseEnd,
    )
}
