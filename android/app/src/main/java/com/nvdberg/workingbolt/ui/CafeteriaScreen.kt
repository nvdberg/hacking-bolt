package com.nvdberg.workingbolt.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.data.Supabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.temporal.ChronoUnit

// ── Cafeteria menu (More → Cafeteria menu) ─────────────────────────────────────
//
// The RGH / Pasqua daily specials are a rotating cycle of weekly pages on the hospital intranet. The Unit Board
// captures each page once into Supabase `cafeteria_menu`; here we pick the page for a date. Mirrors CafeteriaView.swift.

/** The captured menu pages, cached on disk so the menu still shows offline. */
object CafeteriaStore {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    var pages by mutableStateOf<List<Supabase.MenuPage>>(emptyList())
        private set
    var loaded by mutableStateOf(false)
        private set
    private var fetchedAt = 0L
    private var file: File? = null
    private var demoLoaded = false

    private fun open(context: Context) {
        if (file != null) return
        val f = File(context.applicationContext.cacheDir, "wb_menus.json")
        file = f
        runCatching { json.decodeFromString<List<Supabase.MenuPage>>(f.readText()) }.getOrNull()
            ?.let { if (it.isNotEmpty()) { pages = it; loaded = true } }
    }

    /** Re-read at most every 30 min. A failed or empty read keeps the menus we already have. */
    suspend fun load(context: Context?, demo: Boolean) {
        if (demo) {
            if (!demoLoaded) { pages = demoPages(); demoLoaded = true }
            loaded = true
            return
        }
        if (demoLoaded) { demoLoaded = false; pages = emptyList(); loaded = false; file = null }   // left sample mode
        if (context != null) open(context)
        if (System.currentTimeMillis() - fetchedAt < 1_800_000) return
        val p = Supabase.cafeteriaMenus()
        loaded = true
        if (p == null) return
        fetchedAt = System.currentTimeMillis()
        if (p.isEmpty()) return
        pages = p
        val f = file ?: return
        withContext(Dispatchers.IO) { runCatching { f.writeText(json.encodeToString(p)) } }
    }

    class Menu(val day: Supabase.MenuDay, val week: Int, val of: Int)

    /** The menu for [iso] at [site]: a page that prints that date, else the rotation counted from the first page. */
    fun menu(iso: String, site: String): Menu? {
        val ps = pages.filter { it.site == site }.sortedBy { it.page }
        if (ps.isEmpty()) return null
        ps.forEachIndexed { i, p -> p.days?.firstOrNull { it.date == iso }?.let { return Menu(it, i + 1, ps.size) } }
        val ai = ps.indexOfFirst { it.first_date != null }
        if (ai < 0) return null
        val anchor = isoDate(ps[ai].first_date!!) ?: return null
        val day = isoDate(iso) ?: return null
        val diff = ChronoUnit.DAYS.between(anchor, day).toInt()
        val weeks = Math.floorDiv(diff, 7)
        val idx = Math.floorMod(ai + weeks, ps.size)
        val days = ps[idx].days.orEmpty()
        val dow = fmt(iso, "EEEE").uppercase()
        val offset = Math.floorMod(diff, 7)
        val d = days.firstOrNull { (it.weekday ?: "").uppercase().startsWith(dow) }
            ?: days.getOrNull(offset) ?: return null
        return Menu(d, idx + 1, ps.size)
    }

    /** Today's lunch feature at [site] — the subtitle on More's Cafeteria row. */
    fun todaysLunch(site: String): String? {
        val secs = menu(AppViewModel.todayRegina(), site)?.day?.sections.orEmpty()
        val lunch = secs.firstOrNull { (it.label ?: "").contains("lunch feature", ignoreCase = true) }
            ?: secs.firstOrNull { (it.label ?: "").contains("lunch", ignoreCase = true) }
        return lunch?.items?.firstOrNull()?.name?.takeIf { it.isNotBlank() }
    }

    // Sample menus for the no-login preview.
    private fun demoPages(): List<Supabase.MenuPage> {
        val today = isoDate(AppViewModel.todayRegina()) ?: java.time.LocalDate.now()
        val sunday = today.minusDays((today.dayOfWeek.value % 7).toLong())
        val names = listOf("SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY")
        val soups = listOf("Cream of Mushroom", "Beef Barley", "Chicken Noodle", "Roasted Red Pepper", "Split Pea", "Clam Chowder", "Minestrone")
        val mains = listOf(
            "Butter Chicken", "Bacon Cheeseburger with choice of side", "Shepherd's Pie", "Fish & Chips",
            "Perogy Platter", "Lasagna", "Pork Schnitzel",
        )
        fun s(label: String, name: String, price: String) =
            Supabase.MenuSection(label, listOf(Supabase.MenuItem(name, price)))
        fun page(site: String) = Supabase.MenuPage(
            site, 1, sunday.toString(),
            names.mapIndexed { i, w ->
                Supabase.MenuDay(
                    sunday.plusDays(i.toLong()).toString(), w,
                    listOf(
                        s("Café Pizza", "Pepperoni", "$3.75"),
                        s("Today's Soup", soups[i], "Sm - $2.25 Lg - $2.75"),
                        s("Lunch Feature", mains[i], "$8.95"),
                        s("Side", "Mixed Greens with Carrots & Cucumber", "$2.50"),
                        s("Supper Feature", mains[(i + 3) % 7], "$9.25"),
                    ),
                )
            },
        )
        return listOf(page("RGH"), page("PH"))
    }
}

@Composable
fun CafeteriaScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    val context = LocalContext.current
    val today = AppViewModel.todayRegina()
    var iso by remember { mutableStateOf(today) }
    val site = prefs.cafeSite
    val menu = CafeteriaStore.menu(iso, site)

    LaunchedEffect(vm.demo) { CafeteriaStore.load(context, vm.demo) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Cafeteria", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink, modifier = Modifier.weight(1f))
            TextButton(onClick = { iso = today }, enabled = iso != today) { Text("Today", fontSize = 13.sp) }
        }

        // RGH / Pasqua — remembered.
        val shape = RoundedCornerShape(10.dp)
        Row(Modifier.fillMaxWidth().clip(shape).background(c.panel).padding(3.dp)) {
            listOf("RGH" to "RGH", "PH" to "Pasqua").forEach { (key, label) ->
                val on = site == key
                Box(
                    Modifier.weight(1f).clip(RoundedCornerShape(8.dp))
                        .background(if (on) c.accent.copy(alpha = 0.18f) else c.panel)
                        .clickable { prefs.updateCafeSite(key) }
                        .padding(vertical = 7.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label, fontSize = 14.sp, color = if (on) c.accent else c.muted,
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }

        // ‹ Tuesday October 6 ›
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { iso = isoDate(iso)?.minusDays(1)?.toString() ?: iso }) {
                Icon(Icons.Filled.ChevronLeft, contentDescription = "Previous day", tint = c.accent)
            }
            Row(
                Modifier.weight(1f), horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.Bottom,
            ) {
                Text(
                    fmt(iso, "EEEE"), fontSize = 17.sp, fontWeight = FontWeight.Bold,
                    color = if (iso == today) c.accent else c.ink,
                )
                Spacer(Modifier.width(6.dp))
                Text(fmt(iso, "MMMM d"), fontSize = 15.sp, color = c.muted)
            }
            IconButton(onClick = { iso = isoDate(iso)?.plusDays(1)?.toString() ?: iso }) {
                Icon(Icons.Filled.ChevronRight, contentDescription = "Next day", tint = c.accent)
            }
        }

        when {
            menu != null -> {
                lunchFirst(menu.day.sections.orEmpty()).forEach { sec ->
                    val items = sec.items.orEmpty().filter { !it.name.isNullOrBlank() }
                    if (items.isNotEmpty()) {
                        MenuHeader(sec.label ?: "")
                        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.panel)) {
                            items.forEachIndexed { i, it ->
                                if (i > 0) HorizontalDivider(color = c.line, modifier = Modifier.padding(start = 14.dp))
                                Row(
                                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.Top,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    Text(it.name ?: "", fontSize = 16.sp, color = c.ink, modifier = Modifier.weight(1f))
                                    val p = it.price
                                    if (!p.isNullOrBlank()) {
                                        Text(
                                            p, fontSize = 13.sp, color = c.muted, textAlign = TextAlign.End,
                                            style = TextStyle(fontFeatureSettings = "tnum"), modifier = Modifier.padding(top = 2.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                Text(
                    "Menu week ${menu.week} of ${menu.of} · prices as printed. Rotating menu — if today looks off, blame the kitchen.",
                    fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 4.dp, vertical = 10.dp),
                )
            }
            !CafeteriaStore.loaded -> Row(
                Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = c.muted)
                Text("Checking the specials…", fontSize = 14.sp, color = c.muted)
            }
            else -> Text(
                if (CafeteriaStore.pages.any { it.site == site }) "Nothing listed for this day."
                else "No menu yet — it's captured from the hospital intranet. Check back soon.",
                fontSize = 13.sp, color = c.muted, modifier = Modifier.padding(16.dp),
            )
        }
        Spacer(Modifier.height(40.dp))
    }
}

/** Lunch on top, with the side(s) printed right after it; everything else keeps the printed order. */
private fun lunchFirst(secs: List<Supabase.MenuSection>): List<Supabase.MenuSection> {
    fun has(s: Supabase.MenuSection, w: String) = (s.label ?: "").contains(w, ignoreCase = true)
    val li = secs.indexOfFirst { has(it, "lunch") }
    if (li < 0) return secs
    var end = li + 1
    while (end < secs.size && has(secs[end], "side")) end++
    return secs.subList(li, end) + secs.subList(0, li) + secs.subList(end, secs.size)
}

/** Lunch and supper features stand out (☀ / 🌙, accent); the rest get a plain header. */
@Composable
private fun MenuHeader(label: String) {
    val c = Theme.colors
    val l = label.lowercase()
    val icon: ImageVector? = when {
        "lunch" in l -> Icons.Filled.WbSunny
        "supper" in l || "dinner" in l -> Icons.Filled.Bedtime
        else -> null
    }
    val tint = if (icon != null) c.accent else c.muted
    Row(
        Modifier.padding(start = 4.dp, top = 10.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (icon != null) Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
        Text(label, fontSize = 14.sp, fontWeight = if (icon != null) FontWeight.Bold else FontWeight.SemiBold, color = tint)
    }
}
