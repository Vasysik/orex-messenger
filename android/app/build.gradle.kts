import java.util.Properties
import org.gradle.api.GradleException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

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

val orexDistribution = System.getenv("OREX_ANDROID_DISTRIBUTION")
    ?.trim()
    ?.lowercase()
    ?.takeIf { it.isNotEmpty() }
    ?: "stable"
if (orexDistribution != "stable" && orexDistribution != "debug") {
    throw GradleException(
        "OREX_ANDROID_DISTRIBUTION must be stable or debug, got: $orexDistribution",
    )
}

val orexApplicationId = if (orexDistribution == "debug") {
    "ru.orex.messenger.debug"
} else {
    "ru.orex.messenger"
}
val orexAppLabel = if (orexDistribution == "debug") {
    "Orex Messenger Debug"
} else {
    "Мессенджер Orex"
}

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
        applicationId = orexApplicationId
        manifestPlaceholders["orexAppLabel"] = orexAppLabel
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

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}


dependencies {
    testImplementation("junit:junit:4.13.2")

    // Keep Android system-call integration isolated in OrexAndroidTelecomManager
    // so future Core-Telecom upgrades remain native-only. 1.0.1 is the stable
    // bug-fix release for audio routing and endpoint handling.
    implementation("androidx.core:core-telecom:1.0.1")

    // OrexAndroidTelecomManager uses Dispatchers.Main for MethodChannel and
    // Telecom callbacks; make the Android Main dispatcher an explicit app
    // dependency instead of relying on a transitive implementation detail.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // E2EE push decryption may need Matrix I/O and crypto work. Keep that work
    // out of FirebaseMessagingService and run it as expedited background work.
    implementation("androidx.work:work-runtime-ktx:2.11.2")

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
                "config for applicationId $orexApplicationId. For an explicit compile-only CI " +
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

// flutter_vodozemac supplies the E2EE primitives used by Matrix and push
// handling. Older Cargokit Windows scripts can log an error yet return exit
// code 0, which otherwise produces an APK without its native library.
// Verify the final merge instead of allowing such an APK to be tested.
fun registerVodozemacNativeLibsVerification(variant: String) {
    val variantDirectory = variant.replaceFirstChar { it.lowercaseChar() }
    val verificationTask = tasks.register("verify${variant}VodozemacNativeLibs") {
        group = "verification"
        description = "Checks flutter_vodozemac native bindings in $variant."
        dependsOn(
            tasks.matching { task ->
                task.name == "merge${variant}NativeLibs"
            },
        )
        // This task intentionally has no output: the APK must be checked even
        // when Android's native merge itself is already up to date.
        outputs.upToDateWhen { false }

        doLast {
            val mergedNativeLibs = layout.buildDirectory
                .dir(
                    "intermediates/merged_native_libs/$variantDirectory/" +
                        "merge${variant}NativeLibs/out/lib",
                )
                .get()
                .asFile
            val includesVodozemac = mergedNativeLibs.exists() &&
                mergedNativeLibs.walkTopDown().any { candidate ->
                    candidate.isFile &&
                        candidate.name == "libvodozemac_bindings_dart.so"
                }

            if (!includesVodozemac) {
                throw GradleException(
                    "flutter_vodozemac native bindings are missing from the " +
                        "$variant variant. Cargokit must produce " +
                        "libvodozemac_bindings_dart.so.",
                )
            }
        }
    }

    tasks
        .matching { task ->
            task.name == "assemble$variant" ||
                task.name == "package$variant" ||
                task.name == "bundle$variant"
        }
        .configureEach {
            dependsOn(verificationTask)
        }
}

listOf("Debug", "Profile", "Release").forEach(::registerVodozemacNativeLibsVerification)
