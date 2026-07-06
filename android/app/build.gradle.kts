import java.util.Properties
import org.gradle.api.GradleException

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(name: String): String? {
    val fromFile = keystoreProperties.getProperty(name)?.trim()
    if (!fromFile.isNullOrEmpty()) return fromFile
    val envName = "OREX_ANDROID_" + name
        .replace(Regex("([a-z])([A-Z])"), "\$1_\$2")
        .uppercase()
    return System.getenv(envName)?.trim()?.takeIf { it.isNotEmpty() }
}

val releaseStoreFile = signingValue("storeFile")
val releaseKeyAlias = signingValue("keyAlias")
val releaseKeyPassword = signingValue("keyPassword")
val releaseStorePassword = signingValue("storePassword")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseKeyAlias,
    releaseKeyPassword,
    releaseStorePassword,
).all { !it.isNullOrEmpty() }

val googleServicesJson = file("google-services.json")
val allowReleaseWithoutPush = System.getenv("OREX_ALLOW_ANDROID_RELEASE_WITHOUT_PUSH")
    ?.trim()
    ?.equals("true", ignoreCase = true) == true

val allowUnsignedRelease = System.getenv("OREX_ALLOW_UNSIGNED_ANDROID_RELEASE")
    ?.trim()
    ?.equals("true", ignoreCase = true) == true

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// google-services.json не хранится в репозитории. Debug/локальные compile-only
// сборки могут жить без Firebase, но production release fail-closed: Orex не
// должен молча выпускаться без FCM и потом просто не регистрировать pusher.
if (googleServicesJson.exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "ru.orex.messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "ru.orex.messenger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_webrtc / livekit_client требуют minSdk >= 23 (звонки).
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}


dependencies {
    // Keep Android system-call integration isolated in OrexAndroidTelecomManager
    // so future Core-Telecom upgrades remain native-only. 1.0.1 is the stable
    // bug-fix release for audio routing and endpoint handling.
    implementation("androidx.core:core-telecom:1.0.1")

    // OrexAndroidTelecomManager uses Dispatchers.Main for MethodChannel and
    // Telecom callbacks; make the Android Main dispatcher an explicit app
    // dependency instead of relying on a transitive implementation detail.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // Native FCM delivery must work before FlutterEngine exists. Firebase BoM
    // keeps the Android SDK modules on a compatible version set.
    implementation(platform("com.google.firebase:firebase-bom:34.15.0"))
    implementation("com.google.firebase:firebase-messaging")
}

gradle.taskGraph.whenReady {
    val releaseArtifactRequested = allTasks.any { task ->
        val taskName = task.name
        taskName.equals("assembleRelease", ignoreCase = true) ||
            taskName.equals("bundleRelease", ignoreCase = true) ||
            taskName.equals("packageRelease", ignoreCase = true)
    }
    if (releaseArtifactRequested && !googleServicesJson.exists() && !allowReleaseWithoutPush) {
        throw GradleException(
            "Android release cannot be built without push configuration: " +
                "android/app/google-services.json is missing. Download the Firebase Android " +
                "config for applicationId ru.orex.messenger. For an explicit compile-only CI " +
                "check (not a distributable Orex build), set " +
                "OREX_ALLOW_ANDROID_RELEASE_WITHOUT_PUSH=true."
        )
    }
    if (releaseArtifactRequested && !hasReleaseSigning && !allowUnsignedRelease) {
        throw GradleException(
            "Android release signing is not configured. Provide android/key.properties " +
                "or OREX_ANDROID_STORE_FILE, OREX_ANDROID_STORE_PASSWORD, " +
                "OREX_ANDROID_KEY_ALIAS and OREX_ANDROID_KEY_PASSWORD. " +
                "Set OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true only for CI compile checks."
        )
    }
}

flutter {
    source = "../.."
}
