import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Yayin imzasi DEPODA DEGIL.
//
// Anahtar deposu ve parolalari uygulamanin destek klasorunde duruyor
// (`~/Library/Application Support/AndrOS/release-signing.properties`).
// Acik kaynak bir depoda imza anahtari bulunamaz; ayrica anahtari
// kaybetmek "bir daha guncelleme yayinlayamazsin" demek.
//
// Dosya yoksa hata VERMIYORUZ: depoyu klonlayan herkes hata ayiklama
// imzasiyla derleyebilsin.
val signingProps = Properties().apply {
    val f = File(System.getProperty("user.home"),
                 "Library/Application Support/AndrOS/release-signing.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.naer.andros"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.naer.andros"
        minSdk = 26            // Android 8.0 — kullanicinin telefonu Android 11
        targetSdk = 36
        versionCode = 5
        versionName = "0.1.0-beta.5"
    }

    signingConfigs {
        if (signingProps.containsKey("storeFile")) {
            create("release") {
                storeFile = File(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { viewBinding = false }
    sourceSets["main"].java.srcDirs("src/main/kotlin")
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.constraintlayout:constraintlayout:2.2.0")
    // QR tarayici: telefonun kendi kamera uygulamasi QR okumuyor, bu
    // yuzden tarayici UYGULAMANIN ICINDE olmali. ZXing gomulu surumu
    // ML Kit'e gore cok daha kucuk ve Play Hizmetleri gerektirmiyor.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
