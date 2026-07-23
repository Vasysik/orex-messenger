allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// flutter_webrtc 1.5.2 does not surface MediaProjection.Callback.onStop to
// Dart. Compile one narrowly patched source file into its Android plugin
// project so a system revoke/lock can unpublish the LiveKit screen track.
// The overlay validates the pinned package version and leaves every other
// upstream source file untouched.
val flutterWebRtcOverlay = rootProject.file("flutter_webrtc_patch/flutter_webrtc_overlay.gradle")
subprojects {
    if (name == "flutter_webrtc") {
        apply(from = flutterWebRtcOverlay)
    }
}

// flutter_vodozemac 0.5.0 invokes its Cargokit batch runner through a
// process-level FLUTTER_ROOT variable. Gradle does not receive that variable
// when it is launched directly on Windows. Redirect only this task to our
// tracked proxy, which reads the SDK selected in local.properties before
// delegating to Cargokit with its original task inputs.
if (System.getProperty("os.name").startsWith("Windows", ignoreCase = true)) {
    val cargokitProxyPlugin = rootProject.file("cargokit_proxy/gradle/plugin.gradle")

    gradle.projectsEvaluated {
        check(cargokitProxyPlugin.isFile) {
            "Missing Cargokit Windows proxy: ${cargokitProxyPlugin.absolutePath}"
        }

        val vodozemacProject = rootProject.findProject(":flutter_vodozemac")
            ?: return@projectsEvaluated
        vodozemacProject.tasks
            .matching { task ->
                task.name.startsWith("cargokitCargoBuildFlutter_vodozemac")
            }
            .configureEach {
                val setter = javaClass.getMethod("setPluginFile", String::class.java)
                setter.invoke(this, cargokitProxyPlugin.absolutePath)
            }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
