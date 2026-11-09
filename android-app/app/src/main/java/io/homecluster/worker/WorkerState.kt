package io.homecluster.worker

/** Shared, observable-by-polling state of the running service (for the UI and the agent). */
object WorkerState {
    @Volatile var running = false
    @Volatile var rpcAlive = false
    @Volatile var rpcPid: Long? = null
    @Volatile var offeredMb = 0L
    @Volatile var headUrl: String? = null
    @Volatile var lastHeartbeat = 0L
    @Volatile var llamaRef: String = "unknown"
    @Volatile var lanIp: String = "?"
    private val lines = ArrayDeque<String>()

    @Synchronized fun log(s: String) { lines.addLast(s.take(200)); while (lines.size > 40) lines.removeFirst() }
    @Synchronized fun tail(n: Int = 12) = lines.takeLast(n).joinToString("\n")
}
