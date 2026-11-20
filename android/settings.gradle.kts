pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 国内镜像优先。直连 google()/mavenCentral()/gradlePluginPortal() 在国内
        // 经常长时间挂起（实测卡在插件门户上十几分钟无进展）。
        // 镜像里找不到的构件仍会回落到下面三个官方源。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")

// Flutter 引擎产物（io.flutter:arm64_v8a_release 等）由 Flutter 的 Gradle 插件
// 注入一个指向 storage.googleapis.com 的仓库。国内这台机器上该域名被解析到
// 127.0.0.1（连接被拒），导致 checkReleaseDuplicateClasses 阶段解析失败。
// 这里追加同内容的国内镜像仓库；官方仓库仍保留，境外环境不受影响。
dependencyResolutionManagement {
    repositories {
        maven {
            url = uri("https://storage.flutter-io.cn/download.flutter.io")
        }
    }
}
