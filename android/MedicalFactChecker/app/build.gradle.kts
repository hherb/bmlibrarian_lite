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

// One value each, read by both the Android config and cargo-ndk below: the
// APK's ABIs must be exactly the ones the Rust library is built for, and
// cargo-ndk's API level is the app's minimum SDK. 64-bit only (maintainer
// decision 2026-10-17, doc/cross_platform/bmlib_sync/uniffi_spike.md).
val bmlibAbis = listOf("arm64-v8a", "x86_64")
val appMinSdk = 26

android {
    namespace = "com.bmlibrarian.factchecker"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.bmlibrarian.factchecker"
        minSdk = appMinSdk
        targetSdk = 35
        versionCode = 3
        versionName = "1.6.0"

        // Custom test runner for Hilt dependency injection in instrumented tests
        testInstrumentationRunner = "com.bmlibrarian.factchecker.HiltTestRunner"

        // 64-bit only: the ABIs cargo-ndk builds bmlib's Rust library for.
        // A 32-bit APK would ship without the library and crash at its first call.
        ndk {
            abiFilters += bmlibAbis
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

// The relevance-score contract, read the same way and for the same reason.
val llmParityFixtures: File =
    rootProject.file("../../doc/cross_platform/llm_parity")

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
    if (llmParityFixtures.isDirectory) {
        inputs.dir(llmParityFixtures)
            .withPathSensitivity(PathSensitivity.RELATIVE)
            .withPropertyName("llmParityFixtures")
    }
}

// SPIKE (WP-2, doc/cross_platform/bmlib_sync/uniffi_spike.md): bmlib's Rust
// crate through UniFFI. The .so files are built by cargo-ndk from a bmlib
// checkout named by `bmlib.dir` in local.properties (relative to this project's
// root, where local.properties lives) or BMLIB_DIR in the environment (CI: an
// actions/checkout of hherb/bmlib at the pinned commit).
//
// - The checkout must be at the commit the committed Kotlin bindings
//   (org/bmlib/ffi/bmlib_ffi.kt) were generated from: BmlibFFI.pin.json's
//   bmlibCommit, the one pin both apps share. checkBmlibPin refuses any other
//   commit, or uncommitted changes under rust/, before cargo runs, because a
//   library from another commit fails UniFFI's checksum check at its first
//   call. -Pbmlib.allowUnpinnedCommit=true builds anyway, with a warning.
// - With no checkout configured, nothing here runs: a debug build carries no
//   library and BmlibJatsFfiTest skips itself. A release APK or bundle is
//   refused instead (checkBmlibForRelease), so no release ships without it.
val bmlibDir: File? = run {
    val props = Properties()
    val local = rootProject.file("local.properties")
    if (local.isFile) local.inputStream().use { props.load(it) }
    (props.getProperty("bmlib.dir") ?: System.getenv("BMLIB_DIR"))
        ?.takeIf { it.isNotBlank() }
        ?.let { rootProject.file(it) }
}
val bmlibJniLibs = layout.buildDirectory.dir("generated/bmlib/jniLibs")
val bmlibHostLib = layout.buildDirectory.dir("generated/bmlib/host")
val bmlibPinFile: File = rootProject.file("../../Packages/BioMedLit/Frameworks/BmlibFFI.pin.json")
val bmlibAllowUnpinnedProperty = "bmlib.allowUnpinnedCommit"
val bmlibAllowUnpinned: Boolean =
    (findProperty(bmlibAllowUnpinnedProperty) as String?)?.toBoolean() == true
val bmlibLibraryName = "libbmlib_ffi.so"

/** The pin's `bmlibCommit` (a full 40-hex SHA), or null when the pin has none. */
fun bmlibPinnedCommit(pin: File): String? {
    if (!pin.isFile) return null
    return Regex("\"bmlibCommit\"\\s*:\\s*\"([0-9a-f]{40})\"")
        .find(pin.readText())
        ?.groupValues
        ?.get(1)
}

/** The trimmed output of `git -C <dir> <args>`, or null when git fails. */
fun gitOutput(dir: File, vararg args: String): String? {
    val process = ProcessBuilder(listOf("git", "-C", dir.absolutePath) + args)
        .redirectErrorStream(true)
        .start()
    val output = process.inputStream.bufferedReader().readText().trim()
    return if (process.waitFor() == 0) output else null
}

// Every release APK or bundle must carry the library for every ABI it ships.
// Unit tests and debug builds are not hooked, so they keep working (and the
// FFI test keeps skipping) without a bmlib checkout.
val checkBmlibForRelease = tasks.register("checkBmlibForRelease") {
    group = "bmlib"
    description = "Fail a release build that would ship without $bmlibLibraryName"
    val configured = bmlibDir != null
    val abis = bmlibAbis
    doLast {
        if (!configured) {
            throw GradleException(
                "A release build needs bmlib's Rust library ($bmlibLibraryName), and no bmlib " +
                    "checkout is configured. Set bmlib.dir in local.properties, or BMLIB_DIR, to a " +
                    "checkout at BmlibFFI.pin.json's bmlibCommit " +
                    "(doc/cross_platform/bmlib_sync/uniffi_spike.md)."
            )
        }
        val jniLibs = bmlibJniLibs.get().asFile
        val missing = abis.filterNot { File(jniLibs, "$it/$bmlibLibraryName").isFile }
        if (missing.isNotEmpty()) {
            throw GradleException("cargoNdkBmlib produced no $bmlibLibraryName for $missing under $jniLibs")
        }
    }
}
val bmlibReleasePackagingTasks =
    setOf("assembleRelease", "bundleRelease", "packageRelease", "packageReleaseBundle")
tasks.matching { it.name in bmlibReleasePackagingTasks }.configureEach {
    dependsOn(checkBmlibForRelease)
}

if (bmlibDir != null) {
    val rustWorkspace = File(bmlibDir, "rust")
    val rustInputs = fileTree(rustWorkspace) {
        include("bmlib/src/**", "bmlib-ffi/src/**", "**/Cargo.toml", "Cargo.lock", "bmlib-ffi/uniffi.toml")
    }
    // Where the host build lands: CARGO_TARGET_DIR when set (relative to the
    // Rust workspace, where cargo runs), else rust/target. It is passed to
    // cargo as --target-dir too, so a .cargo/config.toml target-dir cannot
    // send cargo and the copy below to different places.
    val cargoTargetDir: File = System.getenv("CARGO_TARGET_DIR")
        ?.takeIf { it.isNotBlank() }
        ?.let { File(it).let { dir -> if (dir.isAbsolute) dir else File(rustWorkspace, it) } }
        ?: File(rustWorkspace, "target")

    val checkBmlibPin = tasks.register("checkBmlibPin") {
        group = "bmlib"
        description = "Refuse a bmlib checkout at another commit than BmlibFFI.pin.json's"
        val checkout = bmlibDir
        val pin = bmlibPinFile
        val allowUnpinned = bmlibAllowUnpinned
        doLast {
            val pinned = bmlibPinnedCommit(pin)
            val head = gitOutput(checkout, "rev-parse", "HEAD")
            val changes = gitOutput(checkout, "status", "--porcelain", "--", "rust")
            val problem = when {
                pinned == null -> "no bmlibCommit could be read from $pin"
                head == null -> "$checkout is not a git checkout, so its commit cannot be checked"
                head != pinned -> "$checkout is at $head, but the committed Kotlin bindings were " +
                    "generated from $pinned (BmlibFFI.pin.json)"
                !changes.isNullOrEmpty() -> "$checkout has uncommitted changes under rust/:\n$changes"
                else -> null
            }
            if (problem != null) {
                if (!allowUnpinned) {
                    throw GradleException(
                        "bmlib's library would not match the committed bindings: $problem. " +
                            "Check out the pinned commit, or pass -P$bmlibAllowUnpinnedProperty=true " +
                            "to build it anyway (a mismatch fails UniFFI's checksum check at the first call)."
                    )
                }
                logger.warn(
                    "WARNING: -P$bmlibAllowUnpinnedProperty=true: building bmlib's library " +
                        "UNPINNED, so it may not match the committed bindings: $problem"
                )
            }
        }
    }

    val cargoNdkBmlib = tasks.register<Exec>("cargoNdkBmlib") {
        group = "bmlib"
        description = "Build $bmlibLibraryName for ${bmlibAbis.joinToString()} with cargo-ndk"
        dependsOn(checkBmlibPin)
        workingDir = rustWorkspace
        inputs.files(rustInputs)
        outputs.dir(bmlibJniLibs)
        // Through bmlib's wrapper, so the builder's paths are not compiled into
        // the shipped library (bmlib#490). A shell script: macOS and Linux only (#596).
        val remapWrapper = File(rustWorkspace, "bmlib-ffi/scripts/with-remapped-paths.sh")
        doFirst {
            if (!remapWrapper.isFile) {
                throw GradleException(
                    "$remapWrapper is missing: this bmlib checkout predates bmlib#490. " +
                        "Check out the pinned commit."
                )
            }
        }
        commandLine(
            listOf(remapWrapper.absolutePath, "cargo", "ndk") +
                bmlibAbis.flatMap { listOf("-t", it) } +
                listOf(
                    "-p", appMinSdk.toString(),
                    "-o", bmlibJniLibs.get().asFile.absolutePath,
                    "build", "-p", "bmlib-ffi", "--profile", "release-ffi"
                )
        )
    }

    // The host build JVM unit tests load through JNA.
    val cargoHostBmlib = tasks.register<Exec>("cargoHostBmlib") {
        group = "bmlib"
        description = "Build the host libbmlib_ffi for JVM unit tests"
        dependsOn(checkBmlibPin)
        workingDir = rustWorkspace
        inputs.files(rustInputs)
        outputs.dir(bmlibHostLib)
        commandLine(
            "cargo", "build", "-p", "bmlib-ffi", "--profile", "release-ffi",
            "--target-dir", cargoTargetDir.absolutePath
        )
        doLast {
            val built = File(cargoTargetDir, "release-ffi")
            // A dylib overwritten in place keeps its old code-signature cache entry on
            // macOS, and the next test JVM that loads it is killed (exit 137) after a re-pin.
            delete(bmlibHostLib)
            copy {
                from(built) {
                    include("libbmlib_ffi.dylib", bmlibLibraryName, "bmlib_ffi.dll")
                }
                into(bmlibHostLib)
            }
            if (bmlibHostLib.get().asFile.listFiles().isNullOrEmpty()) {
                throw GradleException("cargo built no host libbmlib_ffi under $built")
            }
        }
    }

    android.sourceSets.getByName("main").jniLibs.srcDir(bmlibJniLibs)
    tasks.named("preBuild") { dependsOn(cargoNdkBmlib) }
    checkBmlibForRelease.configure { dependsOn(cargoNdkBmlib) }
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
    // 5.19.1, not 5.14.0: 5.14.0's x86_64 libjnidispatch.so has 4 KB-aligned
    // LOAD segments; 5.19.1's are 16 KB-aligned on both shipped ABIs, as
    // Android 15+ devices with 16 KB pages require.
    implementation("net.java.dev.jna:jna:5.19.1@aar")
    testImplementation("net.java.dev.jna:jna:5.19.1")

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
