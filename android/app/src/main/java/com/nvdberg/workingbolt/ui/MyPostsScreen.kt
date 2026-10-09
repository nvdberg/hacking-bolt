package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewModelScope
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.MyPost
import com.nvdberg.workingbolt.model.Units
import kotlinx.coroutines.launch

/** Violet — a shift I've posted (My Posts). The same pair as `Theme.posted` on iOS. */
@Composable
internal fun poolPostedColor(): Color = if (isSystemInDarkTheme()) Color(0xFF9F87FF) else Color(0xFF7C5CFC)

/**
 * The "My Posts" segment in the Pool — shifts I've put up for pickup or swap. Pending ones I'm still waiting
 * on are pinned at the top; the ones that were taken are grouped by month below (newest expanded, older
 * folded away), and the whole "picked up" block hides behind the eye toggle.
 */
@Composable
fun MyPostsList(vm: AppViewModel, posts: List<MyPost>) {
    val c = Theme.colors
    var showCompleted by remember { mutableStateOf(true) }                 // eye toggle — shown by default
    var collapsed by remember { mutableStateOf<Set<String>>(emptySet()) }  // completed-month keys folded away
    var appliedDefaultCollapse by remember { mutableStateOf(false) }
    var cancelTarget by remember { mutableStateOf<MyPost?>(null) }         // pending post awaiting a cancel-confirm
    var cancelError by remember { mutableStateOf<String?>(null) }          // LB rejected the cancel → show a hint
    var cancelling by remember { mutableStateOf(false) }

    val pending = posts.filter { it.status == MyPost.Status.Pending }.sortedBy { it.iso }
    val completed = posts.filter { it.status == MyPost.Status.Completed }
    fun monthKey(p: MyPost) = (p.whenAt ?: p.iso).take(7)                  // "YYYY-MM"
    val completedMonths = completed.map { monthKey(it) }.distinct().sortedDescending()

    // Collapse all but the two most recent months — once, the first time there ARE months (posts load async).
    LaunchedEffect(completedMonths) {
        if (!appliedDefaultCollapse && completedMonths.isNotEmpty()) {
            appliedDefaultCollapse = true
            collapsed = completedMonths.drop(2).toSet()
        }
    }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (pending.isEmpty() && completed.isEmpty()) {
            Text(
                "You haven't posted any shifts.\nGive one away or offer a swap and it'll show up here.",
                color = c.muted, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
            )
        }

        if (pending.isNotEmpty()) {
            SectionHeader("Waiting for pickup", pending.size, Icons.Outlined.Schedule)
            pending.forEach { p ->
                PostCard(p, onCancel = if (p.slotID != null && !cancelling) ({ cancelTarget = p }) else null)
            }
        }

        if (completed.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                SectionHeader("Picked up", completed.size, Icons.Outlined.CheckCircle)
                Spacer(Modifier.weight(1f))
                Icon(
                    if (showCompleted) Icons.Outlined.Visibility else Icons.Outlined.VisibilityOff,
                    contentDescription = if (showCompleted) "Hide picked-up posts" else "Show picked-up posts",
                    tint = c.muted,
                    modifier = Modifier.size(22.dp).clickable { showCompleted = !showCompleted },
                )
            }

            if (showCompleted) {
                completedMonths.forEach { mk ->
                    val rows = completed.filter { monthKey(it) == mk }.sortedByDescending { it.whenAt ?: it.iso }
                    val open = mk !in collapsed
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable { collapsed = if (open) collapsed + mk else collapsed - mk }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "${monthTitle(mk)}  ·  ${rows.size}",
                            fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(
                            if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                            contentDescription = null, tint = c.muted, modifier = Modifier.size(20.dp),
                        )
                    }
                    if (open) rows.forEach { PostCard(it) }
                }
            }
        }

        if (posts.isNotEmpty()) {                                // quiet easter egg — the feature was Hein's idea
            Text(
                "Hein's idea 🤝", fontSize = 11.sp, fontStyle = FontStyle.Italic, color = c.muted,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            )
        }
    }

    cancelTarget?.let { p ->
        AlertDialog(
            onDismissRequest = { cancelTarget = null },
            title = { Text("Cancel this offer?") },
            text = { Text("${p.kind.label} · ${fmt(p.iso, "EEE, MMM d")}. This withdraws it from the pool.") },
            confirmButton = {
                TextButton(onClick = {
                    cancelTarget = null; cancelling = true
                    // On the view model's scope: the withdraw + roster re-read must finish even if the tab changes.
                    vm.viewModelScope.launch {
                        val ok = vm.cancelPost(p)
                        cancelling = false
                        if (!ok) cancelError = "Lightning Bolt didn't cancel it — try withdrawing it in LB."
                    }
                }) { Text("Withdraw offer", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { cancelTarget = null }) { Text("Keep it") } },
        )
    }

    cancelError?.let { msg ->
        AlertDialog(
            onDismissRequest = { cancelError = null },
            title = { Text("Couldn't cancel") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { cancelError = null }) { Text("OK") } },
        )
    }
}

private fun monthTitle(k: String): String {
    val names = listOf("", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    val parts = k.split("-")
    val y = parts.getOrNull(0)?.toIntOrNull()
    val m = parts.getOrNull(1)?.toIntOrNull()
    if (parts.size != 2 || y == null || m == null || m !in 1..12) return k
    return "${names[m]} $y"
}

@Composable
private fun SectionHeader(title: String, count: Int, icon: ImageVector) {
    val c = Theme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, contentDescription = null, tint = c.muted, modifier = Modifier.size(14.dp))
        Text("$title ($count)", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
    }
}

/**
 * One row in My Posts — the shift's date, unit, whether it was a give-away or a swap, and who's on the
 * other end (waiting, or who took it).
 */
@Composable
private fun PostCard(post: MyPost, onCancel: (() -> Unit)? = null) {   // onCancel: pending rows only → withdraw the offer
    val c = Theme.colors
    val info = Units.info[post.unit]
    val color = info?.color ?: Color.Gray
    val posted = poolPostedColor()
    val pending = post.status == MyPost.Status.Pending
    val swap = post.kind == MyPost.Kind.Swap

    val subtitle = if (pending) {
        post.note ?: if (swap) "Swap — waiting for a reply" else "Waiting for a pickup"
    } else {
        val who = post.counterparty ?: "a colleague"
        (if (swap) "Swapped with " else "Picked up by ") + who +
            (post.whenAt?.let { " · " + fmt(it.take(10), "MMM d") } ?: "")
    }

    Row(
        Modifier.fillMaxWidth().height(IntrinsicSize.Min)
            .clip(RoundedCornerShape(16.dp))
            .background(c.panel),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(5.dp).fillMaxHeight().background(color))
        Column(
            Modifier.width(46.dp).padding(start = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(fmt(post.iso, "EEE"), fontSize = 11.sp, color = c.muted)
            Text(fmt(post.iso, "d"), fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, color = color)
            Text(fmt(post.iso, "MMM").uppercase(), fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = c.muted)
        }
        Column(
            Modifier.weight(1f).padding(vertical = 12.dp, horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    info?.short ?: post.unit.name,
                    fontSize = 11.sp, fontWeight = FontWeight.Bold, color = color,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(color.copy(alpha = 0.16f))
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                )
                Text(
                    post.kind.label, fontSize = 9.5.sp, fontWeight = FontWeight.ExtraBold, color = posted,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(posted.copy(alpha = 0.14f))
                        .padding(horizontal = 6.dp, vertical = 1.dp),
                )
            }
            if (post.hoursLabel.isNotEmpty()) Text(post.hoursLabel, fontSize = 12.sp, color = c.muted)
            Text(subtitle, fontSize = 12.sp, color = c.muted)
        }
        Column(
            Modifier.padding(end = 12.dp),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (pending) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Pending", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = posted)
                    Icon(Icons.Outlined.Schedule, contentDescription = null, tint = posted, modifier = Modifier.size(13.dp))
                }
                if (onCancel != null) {
                    Text(
                        "Cancel", fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.clickable { onCancel() }.padding(vertical = 4.dp),
                    )
                }
            } else {
                Text("Taken ✓", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.available)
            }
        }
    }
}
