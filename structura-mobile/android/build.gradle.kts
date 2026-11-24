allprojects {
    repositories {
        google()
        // repo1.maven.org es el mismo Maven Central; va antes porque repo.maven.apache.org
        // no responde desde la red de desarrollo (ver docs/ENTORNO.md).
        maven { url = uri("https://repo1.maven.org/maven2") }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
