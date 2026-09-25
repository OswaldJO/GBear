allprojects {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    if (project.name == "moonlight-stream") {
        project.layout.buildDirectory.set(
            project.file(
                "${System.getProperty("user.home")}/.cache/gbear-companion-native/moonlight-stream",
            ),
        )
    } else {
        project.layout.buildDirectory.value(newBuildDir.dir(project.name))
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
