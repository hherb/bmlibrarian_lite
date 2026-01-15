# Phase 1: Project Setup & Architecture

## Overview

This phase establishes the foundation for the Android MedicalFactChecker app. We'll create a new Android project with proper Gradle configuration, dependency injection, and package structure.

**Estimated Duration**: 1 week
**Prerequisites**: Android Studio, JDK 17+
**Deliverable**: Empty but fully configured Android project

## Tasks

### 1.1 Create Android Project

Create a new Android project in Android Studio:

- **Project name**: MedicalFactChecker
- **Package name**: `com.bmlibrarian.factchecker`
- **Language**: Kotlin
- **Minimum SDK**: API 26 (Android 8.0)
- **Build configuration**: Kotlin DSL (build.gradle.kts)

```bash
# Project location (relative to repository root)
android/MedicalFactChecker/
```

### 1.2 Configure Gradle Build Files

#### Root build.gradle.kts

```kotlin
// build.gradle.kts (project root)
plugins {
    id("com.android.application") version "8.2.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    id("com.google.dagger.hilt.android") version "2.50" apply false
    id("com.google.devtools.ksp") version "1.9.22-1.0.17" apply false
}
```

#### App build.gradle.kts

```kotlin
// app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
    id("kotlin-parcelize")
}

android {
    namespace = "com.bmlibrarian.factchecker"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bmlibrarian.factchecker"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        vectorDrawables {
            useSupportLibrary = true
        }

        // Room schema export for migrations
        ksp {
            arg("room.schemaLocation", "$projectDir/schemas")
        }
    }

    buildTypes {
        debug {
            isDebuggable = true
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.10"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Core Android
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")

    // Compose BOM - manages all Compose versions
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // Room Database
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Retrofit + OkHttp for networking
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // Hilt Dependency Injection
    implementation("com.google.dagger:hilt-android:2.50")
    ksp("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    // Security - Encrypted SharedPreferences
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Markdown rendering
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")

    // JSON parsing
    implementation("com.google.code.gson:gson:2.10.1")

    // XML parsing for PubMed responses
    implementation("org.simpleframework:simple-xml:2.7.1") {
        exclude(group = "stax", module = "stax-api")
        exclude(group = "xpp3", module = "xpp3")
    }

    // PDF generation (optional, can defer to Phase 7)
    // implementation("com.itextpdf:itext7-core:7.2.5")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.0")
    testImplementation("io.mockk:mockk:1.13.9")
    testImplementation("app.cash.turbine:turbine:1.0.0")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.02.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
```

### 1.3 Configure ProGuard Rules

```proguard
# proguard-rules.pro

# Keep Retrofit interfaces
-keep,allowobfuscation interface * {
    @retrofit2.http.* <methods>;
}

# Keep Gson serialized classes
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.bmlibrarian.factchecker.data.remote.** { *; }
-keep class com.bmlibrarian.factchecker.domain.model.** { *; }

# Room
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *

# SimpleXML
-keep public class org.simpleframework.** { *; }
-keep class org.simpleframework.xml.** { *; }
-keepattributes ElementList, Root, Element, Attribute

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
```

### 1.4 Create Application Class

```kotlin
// MedicalFactCheckerApp.kt
package com.bmlibrarian.factchecker

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Application class for MedicalFactChecker.
 * Annotated with @HiltAndroidApp to enable Hilt dependency injection.
 */
@HiltAndroidApp
class MedicalFactCheckerApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // Initialize any app-wide components here
    }
}
```

### 1.5 Create Package Structure

Create the following package structure:

```
com.bmlibrarian.factchecker/
├── di/                      # Dependency injection modules
├── data/
│   ├── local/
│   │   ├── dao/
│   │   ├── entity/
│   │   └── converter/
│   ├── remote/
│   │   ├── llm/
│   │   ├── pubmed/
│   │   └── europepmc/
│   └── repository/
├── domain/
│   ├── model/
│   ├── workflow/
│   └── usecase/
├── ui/
│   ├── navigation/
│   ├── factcheck/
│   │   └── components/
│   ├── report/
│   │   └── components/
│   ├── history/
│   │   └── components/
│   ├── settings/
│   │   └── components/
│   ├── onboarding/
│   ├── theme/
│   └── components/
└── util/
```

### 1.6 Set Up Dependency Injection Modules

#### AppModule

```kotlin
// di/AppModule.kt
package com.bmlibrarian.factchecker.di

import android.content.Context
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module providing application-wide dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideSettingsRepository(
        @ApplicationContext context: Context
    ): SettingsRepository {
        return SettingsRepository(context)
    }
}
```

#### DatabaseModule (placeholder)

```kotlin
// di/DatabaseModule.kt
package com.bmlibrarian.factchecker.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module providing database dependencies.
 * Full implementation in Phase 2.
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    // Room database and DAOs will be provided here
}
```

#### NetworkModule (placeholder)

```kotlin
// di/NetworkModule.kt
package com.bmlibrarian.factchecker.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

/**
 * Hilt module providing network dependencies.
 * Full implementation in Phase 3.
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        val loggingInterceptor = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BODY
        }

        return OkHttpClient.Builder()
            .addInterceptor(loggingInterceptor)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }
}
```

### 1.7 Create Theme Files

#### Colors

```kotlin
// ui/theme/Color.kt
package com.bmlibrarian.factchecker.ui.theme

import androidx.compose.ui.graphics.Color

// Primary colors
val Primary = Color(0xFF1976D2)
val PrimaryVariant = Color(0xFF1565C0)
val OnPrimary = Color.White

// Secondary colors
val Secondary = Color(0xFF26A69A)
val SecondaryVariant = Color(0xFF00897B)
val OnSecondary = Color.White

// Background colors
val Background = Color(0xFFFAFAFA)
val Surface = Color.White
val OnBackground = Color(0xFF212121)
val OnSurface = Color(0xFF212121)

// Verdict colors (matching iOS)
val VerdictSupported = Color(0xFF4CAF50)      // Green
val VerdictLikelySupported = Color(0xFF8BC34A) // Light green
val VerdictUnclear = Color(0xFFFFEB3B)         // Yellow
val VerdictLikelyRefuted = Color(0xFFFF9800)   // Orange
val VerdictRefuted = Color(0xFFF44336)         // Red

// Score colors (1-5 scale)
val Score1 = Color(0xFFE57373)  // Low relevance
val Score2 = Color(0xFFFFB74D)
val Score3 = Color(0xFFFFD54F)
val Score4 = Color(0xFFAED581)
val Score5 = Color(0xFF81C784)  // High relevance

// Utility colors
val Error = Color(0xFFD32F2F)
val OnError = Color.White
```

#### Theme

```kotlin
// ui/theme/Theme.kt
package com.bmlibrarian.factchecker.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val LightColorScheme = lightColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    secondary = Secondary,
    onSecondary = OnSecondary,
    background = Background,
    onBackground = OnBackground,
    surface = Surface,
    onSurface = OnSurface,
    error = Error,
    onError = OnError
)

private val DarkColorScheme = darkColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    secondary = Secondary,
    onSecondary = OnSecondary,
    background = Color(0xFF121212),
    onBackground = Color.White,
    surface = Color(0xFF1E1E1E),
    onSurface = Color.White,
    error = Error,
    onError = OnError
)

/**
 * MedicalFactChecker theme.
 */
@Composable
fun MedicalFactCheckerTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.primary.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
```

#### Typography

```kotlin
// ui/theme/Type.kt
package com.bmlibrarian.factchecker.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val Typography = Typography(
    displayLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 57.sp,
        lineHeight = 64.sp,
        letterSpacing = (-0.25).sp
    ),
    headlineLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 32.sp,
        lineHeight = 40.sp
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 28.sp,
        lineHeight = 36.sp
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 22.sp,
        lineHeight = 28.sp
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.15.sp
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.5.sp
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.25.sp
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp
    )
)
```

### 1.8 Create Main Activity

```kotlin
// MainActivity.kt
package com.bmlibrarian.factchecker

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.bmlibrarian.factchecker.ui.navigation.AppNavigation
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import dagger.hilt.android.AndroidEntryPoint

/**
 * Main activity for MedicalFactChecker.
 * Entry point for the Compose UI.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MedicalFactCheckerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AppNavigation()
                }
            }
        }
    }
}
```

### 1.9 Create Placeholder Navigation

```kotlin
// ui/navigation/AppNavigation.kt
package com.bmlibrarian.factchecker.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

/**
 * Main navigation component.
 * Full implementation in Phase 6.
 */
@Composable
fun AppNavigation() {
    // Placeholder - will be replaced with actual navigation in Phase 6
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Text("MedicalFactChecker - Setup Complete")
    }
}
```

### 1.10 Update AndroidManifest.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- Permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:name=".MedicalFactCheckerApp"
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:supportsRtl="true"
        android:theme="@style/Theme.MedicalFactChecker"
        android:networkSecurityConfig="@xml/network_security_config">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:theme="@style/Theme.MedicalFactChecker">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

    </application>

</manifest>
```

### 1.11 Create Network Security Config

```xml
<!-- res/xml/network_security_config.xml -->
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <!-- Allow cleartext for localhost (Ollama) in debug builds -->
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">localhost</domain>
        <domain includeSubdomains="true">10.0.2.2</domain>
    </domain-config>
</network-security-config>
```

## Verification Checklist

- [ ] Project builds successfully with `./gradlew build`
- [ ] App launches on emulator/device
- [ ] Hilt injection works (no runtime errors)
- [ ] All package directories created
- [ ] Theme colors display correctly
- [ ] ProGuard rules compile without warnings

## Dependencies on Other Phases

- **Phase 2** depends on this phase for: Room database setup
- **Phase 3** depends on this phase for: OkHttpClient, Retrofit setup
- **Phase 6** depends on this phase for: Navigation, Theme

## Next Phase

Continue to [Phase 2: Data Models & SQLite](./02-data-models.md)
