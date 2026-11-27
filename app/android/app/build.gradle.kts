import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 릴리스 서명 정보: app/android/key.properties(gitignore) 또는 환경 변수(CI). 둘 다 없으면 저장소의 고정 테스트 키로 폴백(테스트 설치용, Play 업로드 불가).
// key.properties 키: storeFile, storePassword, keyAlias, keyPassword
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

fun signingValue(propName: String, envName: String): String? =
    (keyProps.getProperty(propName) ?: System.getenv(envName))?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "FITLOG_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "FITLOG_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "FITLOG_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "FITLOG_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }

android {
    namespace = "com.fitlog.fitlog"
    // androidx.core 1.19(플러그인 의존성)가 compileSdk 37 이상을 요구한다(Flutter 기본은 36).
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications가 요구한다(core library desugaring).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 주의: 첫 Play 업로드 전에 확정한다. 업로드 후에는 바꿀 수 없다(app/store/release-checklist.md).
        applicationId = "com.fitlog.fitlog"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 릴리스 키가 없을 때 쓰는 고정 테스트 키(android/test-signing/README.md). 빌드마다 서명이 같아 덮어 설치가 된다.
        create("testSigning") {
            storeFile = rootProject.file("test-signing/fitlog-test.keystore")
            storePassword = "fitlogtest"
            keyAlias = "fitlogtest"
            keyPassword = "fitlogtest"
        }
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else signingConfigs.getByName("testSigning")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Play Integrity Standard API(contracts/v1.0/security.md).
    implementation("com.google.android.play:integrity:1.4.0")
}

flutter {
    source = "../.."
}
