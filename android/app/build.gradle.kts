plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.deniedhashtag.lumet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.deniedhashtag.lumet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Dashcam: camera -> hardware H.264 -> RTMPS, with a simultaneous local MP4
    // written from the same encode. JitPack-only; see the repo in ../build.gradle.kts.
    implementation("com.github.pedroSG94.RootEncoder:library:2.8.1")

    // NotificationCompat / ServiceCompat.startForeground(type).
    //
    // Pinned deliberately: androidx.core 1.19.x declares minCompileSdk 37 and
    // minAndroidGradlePluginVersion 9.1.0 in its AAR metadata, which hard-fails
    // this project (compileSdk 36, AGP 9.0.1). Raise this only together with
    // compileSdk and AGP.
    implementation("androidx.core:core-ktx:1.18.0")

    constraints {
        implementation("androidx.core:core") { version { strictly("1.18.0") } }
        implementation("androidx.core:core-ktx") { version { strictly("1.18.0") } }
    }
}
