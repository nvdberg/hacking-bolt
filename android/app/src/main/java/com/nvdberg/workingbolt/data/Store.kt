package com.nvdberg.workingbolt.data

import android.content.Context
import android.util.Log
import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.OpenShift
import com.nvdberg.workingbolt.model.TimeOffRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * On-disk snapshots, so startup shows the previous data immediately.
 *
 * NOTE: new fields must have defaults so older cached snapshots still decode (a required addition makes the
 * whole cache fail to load and bounces the app to the login screen).
 */
@Serializable
data class Snapshot(
    val open: List<OpenShift> = emptyList(),
    val mine: List<MyShift> = emptyList(),
    val me: String = "",
    val updated: Long = 0L,
    val assigns: List<Assignment> = emptyList(),
)

/**
 * The durable shift log: the on-file record of shifts the logged-in person has worked / will work.
 * PAST shifts are kept forever — even if Lightning Bolt later stops returning old data — while today +
 * future are refreshed live each harvest.
 */
@Serializable
data class LogSnapshot(
    val shifts: List<MyShift> = emptyList(),
    val owner: String = "",
    val historyAt: Long? = null,
    val startUsed: String? = null,
)

@Serializable
data class GroupSnapshot(
    val assigns: List<Assignment> = emptyList(),
    val owner: String = "",
    val loadedAt: Long? = null,
)

/** Reads/writes the JSON snapshots the app keeps in its private files dir. */
class Store(context: Context) {

    private val dir: File = File(context.filesDir, "workingbolt").apply { mkdirs() }
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val cacheFile = File(dir, "wb_cache.json")
    private val logFile = File(dir, "wb_shiftlog.json")
    private val groupFile = File(dir, "wb_grouplog.json")
    private val requestsFile = File(dir, "wb_requests.json")

    suspend fun loadCache(): Snapshot? = read(cacheFile)
    suspend fun saveCache(s: Snapshot) = write(cacheFile, s)

    suspend fun loadLog(): LogSnapshot? = read(logFile)
    suspend fun saveLog(s: LogSnapshot) = write(logFile, s)

    suspend fun loadGroup(): GroupSnapshot? = read(groupFile)
    suspend fun saveGroup(s: GroupSnapshot) = write(groupFile, s)

    suspend fun loadRequests(): List<TimeOffRequest>? = read(requestsFile)
    suspend fun saveRequests(r: List<TimeOffRequest>) = write(requestsFile, r)

    /** Wipe every cached snapshot — used by Sign out so the next person gets their own data. */
    suspend fun clearAll() = withContext(Dispatchers.IO) {
        listOf(cacheFile, logFile, groupFile, requestsFile).forEach { it.delete() }
        Unit
    }

    private suspend inline fun <reified T> read(f: File): T? = withContext(Dispatchers.IO) {
        if (!f.exists()) return@withContext null
        runCatching { json.decodeFromString<T>(f.readText()) }.getOrElse {
            Log.w(WB_LOG, "store: ${f.name} unreadable (${it.message}) — ignoring")
            null
        }
    }

    private suspend inline fun <reified T> write(f: File, value: T) = withContext(Dispatchers.IO) {
        runCatching { f.writeText(json.encodeToString<T>(value)) }
            .onFailure { Log.w(WB_LOG, "store: writing ${f.name} failed (${it.message})") }
        Unit
    }
}
