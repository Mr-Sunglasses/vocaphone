plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.kotlin.multiplatform.library)
}

kotlin {
    android {
        namespace = "com.vocahq.vocaphone.shared"
        compileSdk = 37
        minSdk = 33
        withHostTest {}
    }
    iosArm64()
    iosSimulatorArm64()

    iosArm64().binaries.framework {
        baseName = "VocaPhoneSharedKMP"
        isStatic = true
    }
    iosSimulatorArm64().binaries.framework {
        baseName = "VocaPhoneSharedKMP"
        isStatic = true
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
