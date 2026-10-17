plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.findr.findr_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 改 applicationId 等于换一个 App 身份：老安装的数据目录碰不到、
        // 用户得重装。**没有迁移方案之前别动这一行。**
        // namespace 保持 com.findr.findr_app（那是代码包名，与 App 身份无关，别动）。
        applicationId = "com.findr.app.dev"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionName 来自 pubspec.yaml（就是 `1.0.0` 这种三段版本名），它是**给人看的字符串**。
        versionName = flutter.versionName
        // versionCode 是 Android 判断「谁更新」用的**整数**（只能是整数，不能塞 "1.0.0" 进去），
        // 所以这里由版本名推出来：`1.0.0` → 10000、`1.0.1` → 10001、`1.2.3` → 10203。
        // 这样版本名一变它就自动跟着涨，不用再维护第二个数字；同一个版本名重出包时两者都相同
        // （系统视为同一版，正合我们的语义）。⚠️ 不去读 pubspec 的 `+N` —— 版本号已经改成三段，
        // 没有那个数了（不写 `+N` 时 Flutter 的 `flutter.versionCode` 恒为 1，那样每版都同号）。
        versionCode = run {
            val parts = flutter.versionName.split(".").map { it.trim().toIntOrNull() ?: 0 }
            fun part(i: Int) = parts.getOrElse(i) { 0 }.coerceIn(0, 99)
            part(0) * 10000 + part(1) * 100 + part(2)
        }
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
