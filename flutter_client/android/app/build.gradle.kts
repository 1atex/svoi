plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    buildFeatures { aidl = true }
    namespace = "dev.svoi.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "dev.svoi.app.preview"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        getByName("debug") {
            val testKey = System.getenv("SVOI_ANDROID_TEST_KEYSTORE")
            if (!testKey.isNullOrBlank()) {
                storeFile = file(testKey)
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        create("release") {
            val path = System.getenv("SVOI_ANDROID_KEYSTORE")
            if (!path.isNullOrBlank()) {
                storeFile = file(path)
                storePassword = System.getenv("SVOI_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "svoi"
                keyPassword = System.getenv("SVOI_ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
dependencies {
    implementation(files("libs/svoi-mobile.aar"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release") && (it.name.startsWith("assemble") || it.name.startsWith("package") || it.name.startsWith("bundle")) }) {
        require(!System.getenv("SVOI_ANDROID_KEYSTORE").isNullOrBlank() && !System.getenv("SVOI_ANDROID_KEYSTORE_PASSWORD").isNullOrBlank()) {
            "Release builds require the permanent Android signing key"
        }
    }
}
