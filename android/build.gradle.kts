allprojects {
    repositories {
        google()
        mavenCentral()
        // RootEncoder (camera -> H.264 -> RTMPS) is published to JitPack only.
        // The content filter keeps Gradle from probing JitPack for every
        // androidx/Flutter artifact, which would add seconds of 404s per resolve.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroupByRegex("com\\.github\\.pedroSG94.*") }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
