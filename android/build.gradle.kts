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
// 所有 Android 工程统一用一个 NDK 版本（gradle.properties 的 `findr.ndkVersion`）。
// 为什么必须从根上强制：`jni` 这类插件在自己的 build.gradle 里写死了 `ndkVersion flutter.ndkVersion`
// （Flutter 3.47.5 = 28.2.13676358），而 runner 镜像里只有 30.0 —— 不覆盖就要每次构建现下 700MB
// 的 r28c，v1.0.26 正是在解压它时红的（`Error on ZipFile unknown archive`）。
// 时机很关键：AGP 在**自己的 afterEvaluate** 里就把 NDK 定下来了，之后再改没用（实测在
// projectsEvaluated 里改，构建照样去下 28.2）。这里注册的 afterEvaluate 比 AGP 注册得早，
// 所以先跑、盖住插件脚本里写的值 —— 这也要求它出现在下面那句 `evaluationDependsOn` 之前。
// 用反射取 setNdkVersion，是因为 AGP 的类不一定在这个脚本的编译期 classpath 上。
val forcedNdkVersion = providers.gradleProperty("findr.ndkVersion").get()
subprojects {
    val forceNdkVersion = {
        extensions.findByName("android")?.let { ext ->
            ext.javaClass.methods
                .first { it.name == "setNdkVersion" && it.parameterCount == 1 }
                .invoke(ext, forcedNdkVersion)
        }
    }
    if (state.executed) forceNdkVersion() else afterEvaluate { forceNdkVersion() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
