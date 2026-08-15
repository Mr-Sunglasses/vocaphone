package com.vocahq.vocaphone.local

import android.os.Build
import java.io.File
import java.util.Locale
import kotlin.math.abs

/**
 * A coarse phone class for picking an on-device model.
 *
 * This is not a benchmark. It only combines RAM, CPU cores, the optional
 * Android media performance class, and the max CPU frequency when sysfs
 * exposes it, so a 4 GB phone and a 20 GB phone are not given the same
 * default.
 */
enum class DeviceTier(val displayName: String) {
    CONSTRAINED("Constrained"),
    STANDARD("Standard"),
    FAST("Fast"),
    FLAGSHIP("Flagship"),
}

data class DeviceProfile(
    val totalRamGB: Long,
    val cpuCores: Int = 0,
    val performanceClass: Int = 0,
    val abi: String = "",
    val maxCpuKHz: Int = 0,
    val sherpaAvailable: Boolean = false,
) {
    val arm64: Boolean get() = abi == "arm64-v8a"

    val tier: DeviceTier
        get() {
            if (!arm64 || totalRamGB < 4) return DeviceTier.CONSTRAINED
            val fastClock = maxCpuKHz >= 2_500_000
            val flagshipClock = maxCpuKHz >= 3_000_000
            return when {
                totalRamGB >= 16 ||
                    performanceClass >= 35 ||
                    (totalRamGB >= 12 && performanceClass >= 34) ||
                    (totalRamGB >= 12 && flagshipClock && cpuCores >= 8) ->
                    DeviceTier.FLAGSHIP
                totalRamGB >= 8 ||
                    performanceClass >= 31 ||
                    (totalRamGB >= 6 && fastClock && cpuCores >= 6) ->
                    DeviceTier.FAST
                else -> DeviceTier.STANDARD
            }
        }

    /**
     * How much RAM a recommendation may claim. The OS and keyboard keep the
     * rest. A model still has to fit in [totalRamGB] as well.
     */
    val modelRamBudgetGB: Int
        get() = when (tier) {
            DeviceTier.CONSTRAINED -> totalRamGB.toInt().coerceIn(1, 3)
            DeviceTier.STANDARD -> totalRamGB.toInt().coerceIn(4, 6)
            DeviceTier.FAST -> (totalRamGB.toInt() - 1).coerceIn(4, 8)
            DeviceTier.FLAGSHIP -> (totalRamGB.toInt() - 2).coerceAtLeast(8)
        }

    fun summary(): String = buildString {
        append(tier.displayName)
        append(" class · ")
        append("$totalRamGB GB RAM")
        if (cpuCores > 0) append(" · $cpuCores cores")
        if (maxCpuKHz > 0) {
            append(" · ${"%.1f".format(Locale.US, maxCpuKHz / 1_000_000.0)} GHz")
        }
        append(" · ${modelRamBudgetGB} GB model budget")
    }

    companion object {
        fun current(
            totalRamGB: Long,
            sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
        ): DeviceProfile = DeviceProfile(
            totalRamGB = totalRamGB,
            cpuCores = Runtime.getRuntime().availableProcessors(),
            performanceClass = Build.VERSION.MEDIA_PERFORMANCE_CLASS,
            abi = Build.SUPPORTED_ABIS?.firstOrNull().orEmpty(),
            maxCpuKHz = readMaxCpuKHz(),
            sherpaAvailable = sherpaAvailable,
        )
    }
}

/**
 * Best-effort peak CPU clock. Many phones publish this in sysfs; some do not,
 * and then the tier falls back to RAM, cores, and the performance class.
 */
fun readMaxCpuKHz(cpuRoot: File = File("/sys/devices/system/cpu")): Int {
    val cpus = cpuRoot.listFiles { file ->
        file.isDirectory && file.name.startsWith("cpu") &&
            file.name.drop(3).all { it.isDigit() }
    } ?: return 0
    return cpus.maxOfOrNull { cpu ->
        val freq = File(cpu, "cpufreq/cpuinfo_max_freq")
        if (!freq.canRead()) 0 else freq.readText().trim().toIntOrNull() ?: 0
    } ?: 0
}

fun DeviceProfile.fits(model: LocalModelDescriptor): Boolean {
    if (totalRamGB < model.minimumRamGB) return false
    if (model.minimumRamGB > modelRamBudgetGB) return false
    if (model.engine == LocalModelEngine.SHERPA_ONNX && !sherpaAvailable) return false
    return true
}

/**
 * Higher is better. Family beats file size: a transducer that fits this
 * phone's class is preferred over a larger Whisper weight.
 *
 * Whisper entries are scored by distance from the class this tier wants
 * (tiny on constrained, small on standard, turbo on fast, full large on
 * high-RAM flagship). q5 is the phone default; full precision only wins
 * on flagship. Adding a catalog row does not need a new branch here.
 */
fun scoreModel(model: LocalModelDescriptor, profile: DeviceProfile): Int {
    if (!profile.fits(model)) return Int.MIN_VALUE
    var score = 0
    when (model.sherpaFamily) {
        SherpaFamily.NEMO_TRANSDUCER -> score += 100
        SherpaFamily.MOONSHINE -> score += 80
        SherpaFamily.SENSE_VOICE, SherpaFamily.CANARY -> score += 50
        SherpaFamily.DOLPHIN_CTC, SherpaFamily.NEMO_CTC, SherpaFamily.PARAFORMER -> score += 40
        null -> Unit
    }
    if (model.engine == LocalModelEngine.WHISPER) {
        score += whisperClassScore(model.id, profile)
    }
    if (!model.englishOnly) score += 10
    return score
}

private fun whisperClass(id: String): Int = when {
    "large-v3-turbo" in id -> 5
    "large" in id -> 6
    "medium" in id -> 4
    "small" in id -> 3
    "base" in id -> 2
    else -> 1
}

private fun whisperTarget(profile: DeviceProfile): Int = when (profile.tier) {
    DeviceTier.CONSTRAINED -> 1
    DeviceTier.STANDARD -> 3
    DeviceTier.FAST -> 5
    DeviceTier.FLAGSHIP -> if (profile.totalRamGB >= 16) 6 else 5
}

private fun whisperClassScore(id: String, profile: DeviceProfile): Int {
    val distance = abs(whisperClass(id) - whisperTarget(profile))
    var score = 50 - distance * 12
    score += when {
        "q5" in id && profile.tier == DeviceTier.FLAGSHIP -> -4
        "q5" in id -> 10
        "q8" in id && profile.tier == DeviceTier.FLAGSHIP -> -2
        "q8" in id -> 2
        profile.tier == DeviceTier.FLAGSHIP -> 8
        else -> -6
    }
    return score
}
