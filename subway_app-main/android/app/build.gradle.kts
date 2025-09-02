plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")   // ← 버전 없음 (settings에서 관리)
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.train_system"
    compileSdk = 34
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "com.example.train_system"
        minSdk = 23
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = "11" }

    buildTypes {
        release { signingConfig = signingConfigs.getByName("debug") }
    }
}

flutter { source = "../.." }
