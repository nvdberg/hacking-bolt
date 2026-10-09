package com.nvdberg.workingbolt.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The witty lines shown on the opening screen. Editable in-app (More → Advanced → Witty lines) and saved
 * on the device, so the pool can be tweaked without a rebuild. Seeded with the same defaults as iOS.
 */
class QuipStore private constructor(private val sp: SharedPreferences) {

    companion object {
        private const val KEY = "wb_quips"
        private const val SEP = "\n"

        @Volatile private var instance: QuipStore? = null

        fun get(context: Context): QuipStore = instance ?: synchronized(this) {
            instance ?: QuipStore(
                context.applicationContext.getSharedPreferences("workingbolt", Context.MODE_PRIVATE)
            ).also { instance = it }
        }

        /** The "sleepless nights" line gets a special enlarge effect on the splash. */
        fun isPunch(text: String) = text.contains("sleepless", ignoreCase = true)

        val defaults: List<String> = listOf(
        "Grab the wrong shift and — surprise — you're working it. 🙂",
        "Not responsible for your sleepless nights.",
        "No take-backs: if you tapped it, it's yours.",
        "No “how much does your life suck today?” surveys. 🙂",
        "Tap “Available” and you are, in fact, now available.",
        "Reads your roster so you don't have to squint at it.",
        "Shows what's open. Doesn't judge how you got here.",
        "The pool is deep. The coffee is not.",
        "Every shift, colour-coded. Your regrets, not included.",
        "Post-call is a state of mind — and a legal rest requirement.",
        "We show the shifts. The consequences are between you and your calendar.",
        "Warning: contains other people's night shifts.",
        "If it says 08:00–08:00, believe it.",
        "Available ≠ advisable. You decide.",
        "Pick wisely. Or don't — we're not the scheduling committee.",
        "Swapping shifts since refreshing the roster 40 times a day stopped being fun.",
        "One tap closer to regret-free scheduling. Mostly.",
        "The roster doesn't lie. It just disappoints.",
        "Built by a colleague, not a committee.",
        "Your schedule, minus the doom-scrolling.",
        "Free shifts, hot and fresh. Handle with care.",
        "Coffee not included. It never is.",
        "We flag the conflicts. You still have to live your life.",
        "No pop-ups. No smileys. No “just checking in.”",
        "Rapid Response: the shift, not your reaction to this app.",
        "Somewhere, a shift is open. This app knows which one.",
        "The only pool at the hospital worth checking.",
        "Trades shifts, not stocks. Please don't confuse them.",
        "Yes, the December shifts are real. No, we can't hide them.",
        "If you're reading this, you probably have a shift to cover.",
        "Making questionable scheduling decisions faster than ever.",
        "Unofficial, unaffiliated, and quietly proud of it.",
        "Your future self will have opinions about this pickup.",
        "Colour-coded so you can panic more efficiently.",
        "We don't ask how you're feeling. We already know.",
        "All the open shifts. None of the guilt trip.",
        "Tap gently. It's a legally binding vibe.",
        "The night shift called. This app answered.",
        "More reliable than the on-call room WiFi.",
        "Suspiciously fewer clicks than the actual scheduler.",
        "Pick up a shift, or just admire them from afar.",
        "Sleep is for the unscheduled.",
        "This is what “work–life balance” looks like at 3 a.m.",
        "Every swap is a small act of optimism.",
        "We sort by date. Your priorities are your own business.",
        "Proudly enabling questionable overtime decisions.",
        "The shift board that doesn't ask you to log in every 12 minutes.",
        "You've got this. Or you've got a shift. Same thing.",
        "MSU nights don't advertise themselves. We do.",
        "Consider this your one and only warning label.",
        "Work expands to fill the shifts available.",
        "Everything's fine. That's what the coffee is for.",
        "Optimism is just a temporary shortage of information.",
        "A schedule is a to-do list that fights back.",
        "The plan survives right up until the first phone call.",
        "Multitasking: ruining several things at once, efficiently.",
        "Sleep — the feature everyone praises and no one uses.",
        "Experience is what you get right after you needed it.",
        "There are two kinds of plans: lucky and late.",
        "The early bird gets the shift nobody else wanted.",
        "Hard work pays off eventually. Procrastination pays off now.",
        "If it works, don't touch it. If it doesn't, you touched it.",
        "Deadlines move faster than the speed of light.",
        "Adulthood is mostly googling how to do things.",
        "Do it right, or do it twice.",
        "Behind every calm doctor is a very loud pager.",
        "Some days you're the defibrillator; some days you're the flatline.",
        "Reality called — it wants its overtime back.",
        "Version 0.1, and quietly proud of it.",
        "Held together by good intentions and caffeine.",
        "Built in a few evenings. Don't overthink it.",
        "Not a medical device. Just a very organised one.",
        )
    }

    var quips by mutableStateOf(read())
        private set

    private fun read(): List<String> {
        val raw = sp.getString(KEY, null) ?: return defaults
        val list = raw.split(SEP).filter { it.isNotBlank() }
        return list.ifEmpty { defaults }
    }

    private fun save(list: List<String>) {
        quips = list
        sp.edit().putString(KEY, list.joinToString(SEP)).apply()
    }

    fun add(s: String) {
        val t = s.trim()
        if (t.isNotEmpty()) save(quips + t)
    }

    fun update(i: Int, s: String) {
        if (i !in quips.indices) return
        val t = s.trim()
        save(if (t.isEmpty()) quips.filterIndexed { idx, _ -> idx != i } else quips.toMutableList().also { it[i] = t })
    }

    fun delete(i: Int) {
        if (i in quips.indices) save(quips.filterIndexed { idx, _ -> idx != i })
    }

    fun resetToDefaults() = save(defaults)
}
