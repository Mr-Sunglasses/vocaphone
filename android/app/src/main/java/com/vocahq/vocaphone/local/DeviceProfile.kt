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
    /** BCP-47 language subtag from the phone, used to pick a first-run model. */
    val language: String = "en",
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
            // A 4 GB phone does not have 4 GB available to the model: Android,
            // the keyboard, and the ONNX Runtime all need working memory too.
            // Keeping one GB out of the recommendation budget prevents the
            // 0.6B Parakeet encoder from becoming the default on that tier,
            // while the full catalog remains available as an explicit choice.
            DeviceTier.STANDARD -> (totalRamGB.toInt() - 1).coerceIn(3, 6)
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
            language = Locale.getDefault().language,
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
 * Higher is better. Language match beats family, and a 670 MB transducer is
 * never the automatic default: first-run has to finish on a phone radio.
 *
 * Whisper entries are scored by distance from the class this tier wants.
 * RAM alone never promotes an old phone to a large encoder: devices without a
 * declared Android media performance class stay on base, including the
 * Snapdragon 845 generation. q5 is the phone default; adding a catalog row
 * does not need a new branch here.
 */
fun scoreModel(model: LocalModelDescriptor, profile: DeviceProfile): Int {
    if (!profile.fits(model)) return Int.MIN_VALUE
    var score = 0
    when (model.sherpaFamily) {
        SherpaFamily.MOONSHINE -> score += 80
        SherpaFamily.SENSE_VOICE, SherpaFamily.CANARY, SherpaFamily.PARAFORMER -> score += 50
        SherpaFamily.DOLPHIN_CTC, SherpaFamily.NEMO_CTC -> score += 40
        SherpaFamily.NEMO_TRANSDUCER -> score += 20
        null -> Unit
    }
    if (model.engine == LocalModelEngine.WHISPER) {
        score += whisperClassScore(model.id, profile)
    }
    if (!model.coversLanguage(profile.language)) score -= 100
    if (model.sizeBytes > 500_000_000L) score -= 50
    if (!model.englishOnly) score += 10
    return score
}

internal fun whisperClass(id: String): Int = when {
    "large-v3-turbo" in id -> 5
    "large" in id -> 6
    "medium" in id -> 4
    "small" in id -> 3
    "base" in id -> 2
    else -> 1
}

private fun whisperTarget(profile: DeviceProfile): Int = when (profile.tier) {
    DeviceTier.CONSTRAINED -> 1
    DeviceTier.STANDARD -> 2
    DeviceTier.FAST -> if (profile.performanceClass >= 31) 3 else 2
    DeviceTier.FLAGSHIP -> when {
        profile.performanceClass >= 34 -> 5
        else -> 3
    }
}

private fun whisperClassScore(id: String, profile: DeviceProfile): Int {
    val distance = abs(whisperClass(id) - whisperTarget(profile))
    var score = 50 - distance * 12
    val declaredFlagship = profile.performanceClass >= 34
    score += when {
        "q5" in id && declaredFlagship -> -4
        "q5" in id -> 10
        "q8" in id && declaredFlagship -> -2
        "q8" in id -> 2
        declaredFlagship -> 8
        else -> -6
    }
    return score
}
