package com.nvdberg.workingbolt.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.ShiftStats
import com.nvdberg.workingbolt.model.Units
import com.nvdberg.workingbolt.ui.weekday
import java.io.File
import java.util.Locale

/**
 * Export the shift log to a file and hand it to Android's share sheet. Only ever runs on an explicit tap.
 * Mirrors `ShiftExport` in Stats.swift (CSV + .ics); the iOS PDF export has no counterpart here yet.
 */
object ShiftExport {

    /** The full shift log as CSV — opens directly in Excel / Sheets. */
    fun csv(log: List<MyShift>): String {
        val sb = StringBuilder("Date,Weekday,Unit,Start,End,Hours,Overnight\n")
        for (x in log.sortedBy { it.date }) {
            val h = ShiftStats.hours(x)
            sb.append(x.date).append(',')
                .append(weekday(x.date)).append(',')
                .append(Units.short(x.unit)).append(',')
                .append(x.start).append(',')
                .append(x.end).append(',')
                .append(String.format(Locale.ROOT, "%.1f", h)).append(',')
                .append(if (x.overnight) "yes" else "no").append('\n')
        }
        return sb.toString()
    }

    /**
     * The shifts as an iCalendar (.ics) — imports straight into Google / Apple Calendar with correct times.
     * One exporter for both entry points (My Shifts share button + More → Export): see [ICSExporter].
     */
    fun ics(log: List<MyShift>): String = ICSExporter.ics(log)

    /** My Shifts → share: the whole roster as an .ics, straight to the share sheet ("Add to Calendar"). */
    fun shareCalendar(context: Context, log: List<MyShift>) =
        share(context, ICSExporter.FILE_NAME, "text/calendar", ICSExporter.ics(log))

    /** Write [content] into the app's shared-files dir and open the system share sheet. */
    fun share(context: Context, fileName: String, mime: String, content: String) {
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(dir, fileName).apply { writeText(content) }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(
            Intent.createChooser(intent, "Share shifts").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
