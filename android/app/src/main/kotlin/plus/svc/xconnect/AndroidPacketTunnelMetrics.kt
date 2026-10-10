package plus.svc.xconnect

import android.content.Context
import android.net.TrafficStats
import android.os.Debug
import android.os.Process
import kotlin.math.max

/** Runtime counters for the Android Packet Tunnel shown on the home screen. */
internal object AndroidPacketTunnelMetrics {
    private var previousAtMs = 0L
    private var previousRxBytes = TrafficStats.UNSUPPORTED.toLong()
    private var previousTxBytes = TrafficStats.UNSUPPORTED.toLong()
    private var previousCpuMs = 0L

    @Synchronized
    fun reset(context: Context) {
        previousAtMs = System.currentTimeMillis()
        val uid = context.applicationInfo.uid
        previousRxBytes = TrafficStats.getUidRxBytes(uid)
        previousTxBytes = TrafficStats.getUidTxBytes(uid)
        previousCpuMs = Process.getElapsedCpuTime()
    }

    @Synchronized
    fun snapshot(context: Context): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val elapsedMs = if (previousAtMs == 0L) 0L else max(1L, now - previousAtMs)
        val uid = context.applicationInfo.uid
        val rxBytes = TrafficStats.getUidRxBytes(uid)
        val txBytes = TrafficStats.getUidTxBytes(uid)
        val cpuMs = Process.getElapsedCpuTime()

        val downloadRate = rate(rxBytes, previousRxBytes, elapsedMs)
        val uploadRate = rate(txBytes, previousTxBytes, elapsedMs)
        val cpuPercent = if (elapsedMs > 0L) {
            ((max(0L, cpuMs - previousCpuMs).toDouble() * 100.0) / elapsedMs)
                .coerceIn(0.0, 100.0)
        } else {
            0.0
        }

        previousAtMs = now
        previousRxBytes = rxBytes
        previousTxBytes = txBytes
        previousCpuMs = cpuMs

        return mapOf(
            "downloadBytesPerSecond" to downloadRate,
            "uploadBytesPerSecond" to uploadRate,
            "memoryBytes" to Debug.getPss().toLong() * 1024L,
            "cpuPercent" to cpuPercent,
            "updatedAt" to now,
        )
    }

    fun emptySnapshot(): Map<String, Any?> = mapOf(
        "downloadBytesPerSecond" to null,
        "uploadBytesPerSecond" to null,
        "memoryBytes" to null,
        "cpuPercent" to null,
        "updatedAt" to null,
    )

    private fun rate(current: Long, previous: Long, elapsedMs: Long): Long? {
        if (current < 0L) return null
        if (elapsedMs <= 0L || previous < 0L) return 0L
        return (max(0L, current - previous) * 1000L) / elapsedMs
    }
}
