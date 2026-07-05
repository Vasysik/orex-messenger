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

val allowUnsignedRelease = System.getenv("OREX_ALLOW_UNSIGNED_ANDROID_RELEASE")
    ?.trim()
    ?.equals("true", ignoreCase = true) == true

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

gradle.taskGraph.whenReady {
    val releaseArtifactRequested = allTasks.any { task ->
        val taskName = task.name
        taskName.equals("assembleRelease", ignoreCase = true) ||
            taskName.equals("bundleRelease", ignoreCase = true) ||
            taskName.equals("packageRelease", ignoreCase = true)
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
