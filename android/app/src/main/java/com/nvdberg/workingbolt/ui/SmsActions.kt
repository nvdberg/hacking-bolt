package com.nvdberg.workingbolt.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.SwapOption
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units

// Pre-filled texts for asking a colleague about a swap — the app opens the SMS app, it never sends.

fun swapPretty(iso: String): String = fmt(iso, "EEE MMM d")

/** [mine] = what I'm trading away, e.g. "CCU" or "CCU 20:00–08:00" on a split day. */
fun swapMessage(mine: String, mineDate: String, opt: SwapOption): String =
    "Hi ${opt.firstName}, any chance we could swap — I take your ${Units.short(opt.returnShift.unit)} " +
        "on ${swapPretty(opt.returnShift.date)}, you take my $mine on ${swapPretty(mineDate)}? Thanks!"

fun pickupMessage(shift: MyShift, opt: SwapOption, mine: String = Units.short(shift.unit)): String =
    "Hi ${opt.firstName}, could you pick up my $mine on ${swapPretty(shift.date)}? Thanks!"

/** Open the SMS composer to one number, pre-filled. Nothing is sent until the user taps send. */
fun openSwapText(context: Context, msg: String, cell: String) {
    val digits = cell.filter { it.isDigit() || it == '+' }
    if (digits.isEmpty()) return
    sendTo(context, listOf(digits), msg)
}

/** Open a group SMS to several colleagues at once. Numbers without digits are skipped. */
fun openGroupText(context: Context, msg: String, cells: List<String>) {
    val nums = cells.map { c -> c.filter { it.isDigit() || it == '+' } }.filter { it.isNotEmpty() }
    if (nums.isEmpty()) return
    sendTo(context, nums, msg)
}

private fun sendTo(context: Context, numbers: List<String>, msg: String) {
    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${numbers.joinToString(",")}")).apply {
        putExtra("sms_body", msg)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(intent) }
}
