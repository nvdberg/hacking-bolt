package com.nvdberg.workingbolt.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nvdberg.workingbolt.model.UnitKey

/**
 * On-device settings — the Android stand-in for the app's `@AppStorage` keys. A single process-wide
 * instance so every screen sees the same values without plumbing them through the ViewModel.
 */
class Prefs private constructor(private val sp: SharedPreferences) {

    companion object {
        /** The order units appear as rows in the Who's Working grid — RGH-Rapid on top by default. */
        val DEFAULT_UNIT_ORDER = listOf(
            UnitKey.RR, UnitKey.SICU, UnitKey.MICU, UnitKey.CCU, UnitKey.PHICU, UnitKey.PRR, UnitKey.MSU,
        )

        @Volatile private var instance: Prefs? = null

        fun get(context: Context): Prefs = instance ?: synchronized(this) {
            instance ?: Prefs(
                context.applicationContext.getSharedPreferences("workingbolt", Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }

    /** Which tab the app opens on. */
    var defaultTab by mutableStateOf(sp.getInt("wb_default_tab", 0))
        private set

    /** Open the Pool filtered to "For me". */
    var poolForMe by mutableStateOf(sp.getBoolean("wb_pool_forme", false))
        private set

    /** "\n"-joined doctor names shown in Crew. */
    var selectedDocs by mutableStateOf(sp.getString("wb_selected_docs", "") ?: "")
        private set

    var unitOrder by mutableStateOf(readUnitOrder())
        private set

    /** How long the opening screen holds before the app appears (2–8s, More → App → Start screen). Tap to skip. */
    var splashSecs by mutableStateOf(sp.getFloat("wb_splash_secs", 8f))
        private set

    fun updateSplashSecs(v: Float) {
        val clamped = v.coerceIn(2f, 8f)
        splashSecs = clamped
        sp.edit().putFloat("wb_splash_secs", clamped).apply()
    }

    /** Comma-joined [StatSection] names — the order the My Stats cards appear in. */
    var statsOrder by mutableStateOf(sp.getString("wb_stats_order", "") ?: "")
        private set

    fun updateStatsOrder(v: String) { statsOrder = v; sp.edit().putString("wb_stats_order", v).apply() }

    // ── added with the build-90 sync ─────────────────────────────────────────

    /** "Keep me signed in": re-sign-in silently with the credentials kept on this device (opt-in). */
    var keepSignedIn by mutableStateOf(sp.getBoolean("wb_keep_signed_in", false))
        private set
    fun updateKeepSignedIn(v: Boolean) { keepSignedIn = v; sp.edit().putBoolean("wb_keep_signed_in", v).apply() }

    /** Fingerprint / face unlock before the kept credentials are used (opt-in). */
    var biometricLogin by mutableStateOf(sp.getBoolean("wb_bio_login", false))
        private set
    fun updateBiometricLogin(v: Boolean) { biometricLogin = v; sp.edit().putBoolean("wb_bio_login", v).apply() }

    /** Set by an explicit Sign out — silent auto-login must not bring the previous person back. */
    var signedOut: Boolean
        get() = sp.getBoolean("wb_signed_out", false)
        set(v) { sp.edit().putBoolean("wb_signed_out", v).apply() }

    /** When the Pool's "My posts" segment shows: auto / always / pending. */
    var myPostsMode by mutableStateOf(sp.getString("wb_myposts_mode", "auto") ?: "auto")
        private set
    fun updateMyPostsMode(v: String) { myPostsMode = v; sp.edit().putString("wb_myposts_mode", v).apply() }

    /** First day of the week in the calendars: 0 = Sunday, 1 = Monday. */
    var weekStart by mutableStateOf(sp.getInt("wb_week_start", 0))
        private set
    fun updateWeekStart(v: Int) { weekStart = v; sp.edit().putInt("wb_week_start", v).apply() }

    /** Show the Pool's "Recently taken" list. */
    var showRecentTaken by mutableStateOf(sp.getBoolean("wb_show_recent_taken", true))
        private set
    fun updateShowRecentTaken(v: Boolean) { showRecentTaken = v; sp.edit().putBoolean("wb_show_recent_taken", v).apply() }

    /** My live-calendar feed token (stable; minted once, mirrored from the backend). */
    var calToken by mutableStateOf(sp.getString("wb_cal_token", "") ?: "")
        private set
    fun updateCalToken(v: String) { calToken = v; sp.edit().putString("wb_cal_token", v).apply() }

    // ── added with the build-92 sync ─────────────────────────────────────────

    /** Who's On stethoscope toggle: show the doctors on call. */
    var whoDoctors by mutableStateOf(sp.getBoolean("wb_who_doctors", false))
        private set
    fun updateWhoDoctors(v: Boolean) { whoDoctors = v; sp.edit().putBoolean("wb_who_doctors", v).apply() }

    /** My Shifts day-panel stethoscope (separate from Who's On's): the doctors beside each unit + a Tonight line. */
    var panelDoctors by mutableStateOf(sp.getBoolean("wb_panel_doctors", false))
        private set
    fun updatePanelDoctors(v: Boolean) { panelDoctors = v; sp.edit().putBoolean("wb_panel_doctors", v).apply() }

    /** Cafeteria menu site: "RGH" or "PH" (Pasqua). */
    var cafeSite by mutableStateOf(sp.getString("wb_cafe_site", "RGH") ?: "RGH")
        private set
    fun updateCafeSite(v: String) { cafeSite = v; sp.edit().putString("wb_cafe_site", v).apply() }

    // Plain on-device stores used by the view model (busy days, offer targets, swap bookkeeping).
    fun getString(key: String): String? = sp.getString(key, null)
    fun putString(key: String, v: String?) { sp.edit().apply { if (v == null) remove(key) else putString(key, v) }.apply() }
    fun getIntSet(key: String): Set<Int> =
        sp.getString(key, null)?.split(",")?.mapNotNull { it.toIntOrNull() }?.toSet() ?: emptySet()
    fun putIntSet(key: String, v: Set<Int>) { sp.edit().putString(key, v.joinToString(",")).apply() }

    fun updateDefaultTab(v: Int) { defaultTab = v; sp.edit().putInt("wb_default_tab", v).apply() }

    fun updatePoolForMe(v: Boolean) { poolForMe = v; sp.edit().putBoolean("wb_pool_forme", v).apply() }

    fun updateSelectedDocs(v: String) { selectedDocs = v; sp.edit().putString("wb_selected_docs", v).apply() }

    fun updateUnitOrder(v: List<UnitKey>) {
        unitOrder = v
        sp.edit().putString("wb_whoson_order", v.joinToString(",") { it.name }).apply()
    }

    fun moveUnit(from: Int, to: Int) {
        val list = unitOrder.toMutableList()
        if (from !in list.indices || to !in list.indices) return
        list.add(to, list.removeAt(from))
        updateUnitOrder(list)
    }

    fun resetUnitOrder() = updateUnitOrder(DEFAULT_UNIT_ORDER)

    private fun readUnitOrder(): List<UnitKey> {
        val raw = sp.getString("wb_whoson_order", null)?.split(",").orEmpty().filter { it.isNotBlank() }
        if (raw.isEmpty()) return DEFAULT_UNIT_ORDER
        val parsed = raw.mapNotNull { name -> runCatching { UnitKey.valueOf(name) }.getOrNull() }
        // forward-compat: keep any unit that isn't in the saved order yet
        return parsed + DEFAULT_UNIT_ORDER.filter { it !in parsed }
    }
}
