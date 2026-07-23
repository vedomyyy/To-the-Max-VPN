import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
        signingConfigs {
            create("release") {
                val keystorePropsFile = rootProject.file("key.properties")
                if (keystorePropsFile.exists()) {
                    val keystoreProps = Properties().apply {
                        keystorePropsFile.inputStream().use { load(it) }
                    }

                    val storeFilePath = keystoreProps.getProperty("storeFile")
                    if (!storeFilePath.isNullOrBlank()) {
                        storeFile = file(storeFilePath)
                        storePassword = keystoreProps.getProperty("storePassword")
                        keyAlias = keystoreProps.getProperty("keyAlias")
                        keyPassword = keystoreProps.getProperty("keyPassword")
                    }
                }
            }
        }

    namespace = "com.example.vpn_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.vpn_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            signingConfig = if (releaseSigning.storeFile != null) {
                releaseSigning
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // ═══ КРИТИЧНО: извлечь .so файлы из APK на диск ═══
    // Без этого libtun2socks.so остаётся внутри APK и
    // не может быть запущен как процесс через ProcessBuilder
    packaging {
        jniLibs {
            useLegacyPackaging = true
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
