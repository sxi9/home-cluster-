plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.homecluster.worker"
    compileSdk = 34

    defaultConfig {
        applicationId = "io.homecluster.worker"
        minSdk = 26           // Android 8.0+
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
    }
    // rpc-server ships as "librpc-server.so" and is executed from the app's native
    // library directory: the only place Android lets an app run a binary from.
    packaging { jniLibs { useLegacyPackaging = true } }
    buildFeatures { buildConfig = true }
    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
