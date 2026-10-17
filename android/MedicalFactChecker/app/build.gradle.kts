// app/build.gradle.kts
// MedicalFactChecker Android App - Module Build Configuration

import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
    id("kotlin-parcelize")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.bmlibrarian.factchecker"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.bmlibrarian.factchecker"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "1.6.0"

        // Custom test runner for Hilt dependency injection in instrumented tests
        testInstrumentationRunner = "com.bmlibrarian.factchecker.HiltTestRunner"

        // 64-bit only: the ABIs cargo-ndk builds bmlib's Rust library for
        // (maintainer decision 2026-10-17, doc/cross_platform/bmlib_sync/uniffi_spike.md).
        // A 32-bit APK would ship without the library and crash at its first call.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }

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

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

// The transparency parity guard (#105) reads its fixtures from the shared
// cross-platform contract at the repository root, outside every Gradle source
// set. Declaring that directory as a test input is what makes an edit to the
// contract alone invalidate the test task: without it Gradle sees no changed
// input, reports UP-TO-DATE, and the Android half of the drift guard silently
// does not run — precisely the incomplete-edit case the guard exists to catch.
val transparencyParityFixtures: File =
    rootProject.file("../../doc/cross_platform/transparency_parity")

// The answered-lookup verb contract (#447), read the same way and for the same
// reason: an edit to the contract alone must re-run the Android half.
val requestFailureParityFixtures: File =
    rootProject.file("../../doc/cross_platform/request_failure_parity")

// The Unpaywall landing-page contract (#464), read the same way and for the same
// reason: an edit to the contract alone must re-run the Android half.
val fulltextParityFixtures: File =
    rootProject.file("../../doc/cross_platform/fulltext_parity")

tasks.withType<Test>().configureEach {
    // Absent in a partial checkout of android/ alone; the test itself fails with
    // a clear message in that case, so do not break configuration over it.
    if (transparencyParityFixtures.isDirectory) {
        inputs.dir(transparencyParityFixtures)
            .withPathSensitivity(PathSensitivity.RELATIVE)
            .withPropertyName("transparencyParityFixtures")
    }
    if (requestFailureParityFixtures.isDirectory) {
        inputs.dir(requestFailureParityFixtures)
            .withPathSensitivity(PathSensitivity.RELATIVE)
            .withPropertyName("requestFailureParityFixtures")
    }
    if (fulltextParityFixtures.isDirectory) {
        inputs.dir(fulltextParityFixtures)
            .withPathSensitivity(PathSensitivity.RELATIVE)
            .withPropertyName("fulltextParityFixtures")
    }
}

// SPIKE (WP-2, doc/cross_platform/bmlib_sync/uniffi_spike.md): bmlib's Rust
// crate through UniFFI. The .so files are built by cargo-ndk from a bmlib
// checkout named by `bmlib.dir` in local.properties or BMLIB_DIR in the
// environment (CI: an actions/checkout of hherb/bmlib at the pinned tag). With
// neither set nothing here runs, the app builds without the library, and
// BmlibJatsFfiTest skips itself.
val bmlibDir: File? = run {
    val props = Properties()
    val local = rootProject.file("local.properties")
    if (local.isFile) local.inputStream().use { props.load(it) }
    (props.getProperty("bmlib.dir") ?: System.getenv("BMLIB_DIR"))?.let { file(it) }
}
val bmlibJniLibs = layout.buildDirectory.dir("generated/bmlib/jniLibs")
val bmlibHostLib = layout.buildDirectory.dir("generated/bmlib/host")

if (bmlibDir != null) {
    val rustWorkspace = File(bmlibDir, "rust")
    val rustInputs = fileTree(rustWorkspace) {
        include("bmlib/src/**", "bmlib-ffi/src/**", "**/Cargo.toml", "Cargo.lock", "bmlib-ffi/uniffi.toml")
    }

    // Android ABIs: the two the spike measures (arm64-v8a devices, x86_64
    // emulators). armeabi-v7a would be one more `-t`.
    val cargoNdkBmlib = tasks.register<Exec>("cargoNdkBmlib") {
        group = "bmlib"
        description = "Build libbmlib_ffi.so for arm64-v8a and x86_64 with cargo-ndk"
        workingDir = rustWorkspace
        inputs.files(rustInputs)
        outputs.dir(bmlibJniLibs)
        commandLine(
            "cargo", "ndk", "-t", "arm64-v8a", "-t", "x86_64", "-p", "26",
            "-o", bmlibJniLibs.get().asFile.absolutePath,
            "build", "-p", "bmlib-ffi", "--profile", "release-ffi"
        )
    }

    // The host build JVM unit tests load through JNA.
    val cargoHostBmlib = tasks.register<Exec>("cargoHostBmlib") {
        group = "bmlib"
        description = "Build the host libbmlib_ffi for JVM unit tests"
        workingDir = rustWorkspace
        inputs.files(rustInputs)
        outputs.dir(bmlibHostLib)
        commandLine("cargo", "build", "-p", "bmlib-ffi", "--profile", "release-ffi")
        doLast {
            copy {
                from(File(rustWorkspace, "target/release-ffi")) {
                    include("libbmlib_ffi.dylib", "libbmlib_ffi.so", "bmlib_ffi.dll")
                }
                into(bmlibHostLib)
            }
        }
    }

    android.sourceSets.getByName("main").jniLibs.srcDir(bmlibJniLibs)
    tasks.named("preBuild") { dependsOn(cargoNdkBmlib) }
    tasks.withType<Test>().configureEach {
        dependsOn(cargoHostBmlib)
        systemProperty("jna.library.path", bmlibHostLib.get().asFile.absolutePath)
    }
}

dependencies {
    // Core Android
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
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
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Kotlin Serialization (preferred over Gson for Kotlin)
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")
    implementation("com.jakewharton.retrofit:retrofit2-kotlinx-serialization-converter:1.0.0")

    // Retrofit Scalars converter for raw string responses (XML from PubMed)
    implementation("com.squareup.retrofit2:converter-scalars:2.9.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // Hilt Dependency Injection
    implementation("com.google.dagger:hilt-android:2.50")
    ksp("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    // Security - Encrypted SharedPreferences
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // MediaPipe - Text Embedding for semantic similarity scoring
    // Uses Universal Sentence Encoder for on-device embeddings
    implementation("com.google.mediapipe:tasks-text:0.10.14")

    // Markdown rendering
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")
    implementation("io.noties.markwon:html:4.6.2")

    // PDF generation (AGPL license - compatible with open source projects)
    implementation("com.itextpdf:itext7-core:7.2.5")

    // Note: XML parsing uses built-in Android XmlPullParser - no external dependency needed
    // This is more efficient for large PubMed XML documents

    // TensorFlow Lite for on-device embeddings
    implementation("org.tensorflow:tensorflow-lite:2.14.0")
    implementation("org.tensorflow:tensorflow-lite-support:0.4.4")
    // Optional: NNAPI delegate for hardware acceleration on supported devices
    implementation("org.tensorflow:tensorflow-lite-gpu-delegate-plugin:0.4.4")

    // SPIKE (WP-2): UniFFI's Kotlin bindings call the Rust library through JNA.
    // The AAR carries JNA's dispatch library for each Android ABI; JVM unit
    // tests need the JAR, which carries the desktop ones (darwin-aarch64 etc.).
    implementation("net.java.dev.jna:jna:5.14.0@aar")
    testImplementation("net.java.dev.jna:jna:5.14.0")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.0")
    testImplementation("io.mockk:mockk:1.13.9")
    testImplementation("app.cash.turbine:turbine:1.0.0")
    // Local HTTP server for tests that check what reaches the wire (#243);
    // keep in step with the okhttp version above
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // A real XmlPullParser for JVM tests of the JATS parser: android.jar's
    // org.xmlpull classes are stubs that throw "not mocked" (#398)
    testImplementation("net.sf.kxml:kxml2:2.3.0")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.02.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")

    // Hilt testing
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.50")
    kspAndroidTest("com.google.dagger:hilt-compiler:2.50")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
