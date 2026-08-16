plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.room)
}

import java.util.Properties

android {
    namespace = "com.vocahq.vocaphone"
    // Current AndroidX releases require compiling against API 37. targetSdk
    // stays at 36, which is what Play requires from 31 August 2026.
    compileSdk = 37
    compileSdkMinor = 0

    defaultConfig {
        applicationId = "com.vocahq.vocaphone"
        minSdk = 33
        targetSdk = 36
        versionCode = 13
        versionName = "0.1.0-beta.13"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    // The keyboard's word list and bigram table are one file each, shared with
    // the iOS keyboard from the repository root. Two hand-maintained copies of
    // a 10 000-word list drift, and nothing would notice until the two
    // platforms started suggesting different words.
    sourceSets {
        getByName("main") {
            assets.srcDir("${rootDir}/../assets/keyboard")
        }
    }

    flavorDimensions += "distribution"

    productFlavors {
        // Everything the project ships itself. sherpa-onnx reaches Android as a
        // prebuilt JNI library, so its .so files live in this flavor's source
        // set rather than in src/main.
        create("full") {
            dimension = "distribution"
            isDefault = true
            buildConfigField("boolean", "SHERPA_ONNX", "true")
        }
        // F-Droid builds every byte it ships from source, which rules out the
        // prebuilt sherpa-onnx and ONNX Runtime libraries. This flavor drops
        // them and leaves whisper.cpp, which is compiled from the pinned
        // submodule, as the on-device engine.
        create("fdroid") {
            dimension = "distribution"
            buildConfigField("boolean", "SHERPA_ONNX", "false")
        }
    }

    if (!project.hasProperty("skipNative")) {
        ndkVersion = "27.2.12479018"
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/whisper/CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }

    signingConfigs {
        create("release") {
            // Reads android/keystore.properties (gitignored) on dev machines and
            // falls back to CI env vars injected from GitHub secrets.
            val props = Properties().apply {
                val propFile = rootProject.file("keystore.properties")
                if (propFile.exists()) propFile.inputStream().use { load(it) }
            }
            val env = System.getenv()
            val storePath = props.getProperty("storeFile") ?: env["KEYSTORE_FILE"]
            val storePass = props.getProperty("storePassword") ?: env["KEYSTORE_PASSWORD"]
            val alias = props.getProperty("keyAlias") ?: env["KEY_ALIAS"]
            val keyPass = props.getProperty("keyPassword") ?: env["KEY_PASSWORD"]
            if (storePath != null) storeFile = file(storePath)
            if (storePass != null) storePassword = storePass
            if (alias != null) keyAlias = alias
            if (keyPass != null) keyPassword = keyPass
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Builders without the keystore -- F-Droid, or anyone checking out
            // the tree -- get an unsigned release APK instead of a Gradle
            // failure over a signing config that could not be populated.
            signingConfig = signingConfigs.getByName("release").takeIf { it.storeFile != null }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    androidComponents {
        onVariants(selector().all()) { variant ->
            variant.outputs.forEach { output ->
                output.outputFileName.set("vocaphone-${variant.name}.apk")
            }
        }
    }

    compileOptions {
        // The bytecode level is not the reproducibility knob: F-Droid rebuilds
        // this APK on JDK 21, and byte-identical output requires compiling with
        // the same JDK, whatever the target level. The project builds on JDK 21
        // (gradle-daemon-jvm.properties, setup-android) for that reason.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    lint {
        abortOnError = true
        // targetSdk 36 is deliberate: it is what Play requires from 31 August
        // 2026, and moving further would opt the app into runtime behaviour it
        // has not been tested against on a physical Pixel.
        disable += "OldTargetApi"
        // The Compose compiler plugin has to match the Kotlin version AGP builds
        // with, so it cannot simply track the newest release.
        disable += "NewerVersionAvailable"
    }
}

kotlin {
    compilerOptions {
        // Kept at 17 on purpose, matching compileOptions above; see the comment
        // there on why the compiling JDK (21), not this level, is what has to
        // agree with the F-Droid buildserver.
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

room {
    schemaDirectory("$projectDir/schemas")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.okhttp)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.zxing.core)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    // The unit-test android.jar only stubs org.json; the real implementation lets
    // the gateway client be tested against MockWebServer on a plain JVM.
    testImplementation(libs.json)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
