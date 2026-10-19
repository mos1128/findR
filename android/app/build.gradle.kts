import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 正式签名 ────────────────────────────────────────────────────────────────
// 凭据在 `android/key.properties`（**不进版本库**，见 android/.gitignore），
// 证书在 `android/app/findr-release.jks`（同样不进版本库）。
// ⚠️ 为什么要正式证书而不是 debug：debug 证书是「谁构建、用谁机器上的」——
//    CI 每次在临时虚拟机上构建，证书和上一版对不上，系统会拒绝覆盖安装
//    （INSTALL_FAILED_UPDATE_INCOMPATIBLE），「应用内更新」直接失效。
//    2026-10-19 实测：CI 发的包与本机打的包，证书指纹就是两个。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        FileInputStream(keystorePropsFile).use { load(it) }
    }
}

android {
    namespace = "com.findr.findr_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (keystorePropsFile.exists()) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

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
        debug {
            // 🚨 调试包也签**同一把正式证书**。否则 `flutter run` 打出的 debug 包（debug 证书）
            //    与正式包（正式证书）**包名相同、签名不同** ⇒ 系统拒绝覆盖安装
            //    （INSTALL_FAILED_UPDATE_INCOMPATIBLE），来回切一次就得卸载一次、记忆库全没。
            //    签同一把之后：debug 包 ⇄ 正式包可以互相覆盖，数据一直留着。
            //    ⚠️ 只改「用哪个密钥签」，热重载等调试能力一点没少；debug 包依然是 debuggable。
            //    没有 key.properties 时（别人 clone 下来跑）退回 debug 证书，开箱照样能跑。
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
        release {
            // 有 android/key.properties 就用正式证书；没有则退回 debug 并**大声警告**
            // （CI 里另有一道断言：打出来的包若还是 debug 证书就让构建直接红 —— 见 workflow）。
            val releaseSigning = signingConfigs.findByName("release")
            if (releaseSigning == null) {
                logger.warn(
                    "⚠️ 没有 android/key.properties ⇒ release 包会用 debug 证书。" +
                        "这种包用户装不上下一版（签名不一致），别拿它发布。",
                )
                signingConfig = signingConfigs.getByName("debug")
            } else {
                signingConfig = releaseSigning
            }
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
