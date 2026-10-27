import java.io.File
import java.util.Properties
import org.gradle.process.CommandLineArgumentProvider

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.isFile) {
    localPropertiesFile.inputStream().use { input -> localProperties.load(input) }
}

fun releaseSigningValue(name: String): String? =
    providers.gradleProperty(name).orNull
        ?: providers.environmentVariable(name).orNull
        ?: localProperties.getProperty(name)

fun requiredReleaseSigningValue(name: String): String? =
    releaseSigningValue(name)?.takeIf { it.isNotBlank() }

val releaseKeystorePath = requiredReleaseSigningValue("KEYSTORE_FILE")?.trim()
val releaseKeystoreFile = releaseKeystorePath?.let { path ->
    if (path.startsWith("../") || path.startsWith("..\\")) {
        rootProject.file(path.substring(3))
    } else {
        rootProject.file(path)
    }
}
val releaseStorePassword = requiredReleaseSigningValue("KEYSTORE_PASSWORD")
val releaseKeyAlias = requiredReleaseSigningValue("KEY_ALIAS")
val releaseKeyPassword = requiredReleaseSigningValue("KEY_PASSWORD")
val releaseSigningProblems = mutableListOf<String>().apply {
    when {
        releaseKeystoreFile == null -> add("KEYSTORE_FILE is not configured")
        !releaseKeystoreFile.isFile -> add("the configured release keystore is unavailable")
        !releaseKeystoreFile.canRead() -> add("the configured release keystore is not readable")
    }
    if (releaseStorePassword == null) add("KEYSTORE_PASSWORD is not configured")
    if (releaseKeyAlias == null) add("KEY_ALIAS is not configured")
    if (releaseKeyPassword == null) add("KEY_PASSWORD is not configured")
}
val releaseSigningReady = releaseSigningProblems.isEmpty()

val supportedAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

// The ABI of the connected device, asked for by the install tasks.
//
// The ABI decides how many native binaries cargo builds (one `cargo ndk` run
// per ABI) and which APK splits get packaged, so it has to be known before the
// build is configured - hence the adb query at configuration time.
//
// Only the install tasks ask for it. `assemble*` must keep all three ABIs:
// scripts/build_apk.sh copies the three splits and the universal APK into
// app/release/, and the universal APK only exists when more than one ABI is
// selected.
//
// The query result becomes part of the configuration cache entry, so a device
// that changed after the entry was stored keeps the old ABI. The install then
// fails with a clear error instead of installing the wrong APK; -Pcsqtt.abis
// overrides the detection and invalidates the entry.
val installTaskRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.substringAfterLast(':').contains("installCsqtt", ignoreCase = true)
}

// An explicit list wins over everything, and it also means no device is
// needed for the build: the install itself then fails in install_apk.sh,
// where the device belongs.
val explicitAbis = providers.gradleProperty("csqtt.abis").orNull
    ?.split(',')?.map(String::trim)?.filter(String::isNotEmpty)?.distinct()

// The ABI Android Studio injects for the selected device. It is enough on its
// own, so no device has to be asked about.
val injectedAbi = providers.gradleProperty("android.injected.build.abi").orNull

var deviceAbi: String? = null
var deviceSerial: String? = null
if (installTaskRequested && explicitAbis.isNullOrEmpty() && injectedAbi.isNullOrBlank()) {
    val helper = rootProject.layout.projectDirectory.file("scripts/device_abi.sh").asFile.absolutePath
    val probe = providers.exec {
        commandLine("bash", helper)
        isIgnoreExitValue = true
    }
    val stdout = probe.standardOutput.asText.orNull.orEmpty()
    val stderr = probe.standardError.asText.orNull.orEmpty()
    val fields = stdout.lineSequence()
        .mapNotNull { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) null else line.substring(0, separator).trim() to line.substring(separator + 1).trim()
        }
        .toMap()
    val abi = fields["abi"]
    val serial = fields["serial"]
    if (abi.isNullOrBlank() || serial.isNullOrBlank()) {
        val reason = stderr.trim().takeIf { it.isNotEmpty() }?.let { "\n$it" } ?: ""
        throw GradleException(
            "No device found for the install task.$reason" +
                "\nConnect a device with USB debugging, or name the ABI explicitly: -Pcsqtt.abis=arm64-v8a"
        )
    }
    deviceAbi = abi
    deviceSerial = serial
    println("Device: $serial ($abi)")
}

// Priority: explicit -Pcsqtt.abis, then the ABI Android Studio injects for the
// currently selected device (android.injected.build.abi), then the ABI of the
// connected device, then all three.
// Deploying from the IDE therefore links one ABI instead of three, an install
// from the console links the ABI of the device, and a plain build still
// produces a complete APK.
val selectedAbis = explicitAbis
    ?: injectedAbi
        ?.split(',')?.map(String::trim)?.filter { it in supportedAbis }?.distinct()
    ?: deviceAbi?.let { listOf(it) }
    ?: supportedAbis
require(selectedAbis.isNotEmpty() && selectedAbis.all { it in supportedAbis }) {
    "csqtt.abis must contain supported ABIs: ${supportedAbis.joinToString()}"
}

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    group = "verification"
    description = "Verifies that a release build has an explicit, readable signing configuration."
    inputs.property("releaseSigningProblems", releaseSigningProblems.joinToString("; "))
    doLast {
        val signingProblems = inputs.properties["releaseSigningProblems"] as String
        check(signingProblems.isEmpty()) {
            "Release signing is not configured: $signingProblems. " +
                "Provide the required values through Gradle properties, environment variables, " +
                "or an untracked local.properties file."
        }
    }
}

android {
    namespace = "com.csqtt.client"
    compileSdk = 37

    defaultConfig {
        applicationId = "csqtt.quic.amurcanov"
        minSdk = 26
        targetSdk = 37
        versionCode = 230
        versionName = "2.5.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

    }

    splits {
        abi {
            isEnable = true
            reset()
            include(*selectedAbis.toTypedArray())
            isUniversalApk = selectedAbis.size > 1
        }
    }

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                storeFile = requireNotNull(releaseKeystoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libclient.so"
            keepDebugSymbols += "**/libandroidx.graphics.path.so"
            keepDebugSymbols += "**/libdatastore_shared_counter.so"
        }
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "/META-INF/INDEX.LIST"
            excludes += "/META-INF/DEPENDENCIES"
            excludes += "/META-INF/LICENSE.md"
            excludes += "/META-INF/NOTICE.md"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        checkReleaseBuilds = true
        abortOnError = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add("src/main/jniLibs")
        }
    }
}

tasks.configureEach {
    val taskName = name.lowercase()
    val preparesReleaseBuild = taskName == "prereleasebuild"
    val producesReleaseArtifact = taskName.contains("release") &&
        (taskName.startsWith("assemble") ||
            taskName.startsWith("bundle") ||
            taskName.startsWith("package") ||
            taskName.startsWith("sign") ||
            taskName.startsWith("install") ||
            taskName.startsWith("publish") ||
            taskName.startsWith("upload"))
    if (preparesReleaseBuild || producesReleaseArtifact) {
        dependsOn(verifyReleaseSigning)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.19.0")
    implementation(platform("androidx.compose:compose-bom:2026.08.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.datastore:datastore-preferences:1.2.1")
    implementation("com.hierynomus:sshj:0.38.0") {
        exclude(group = "org.bouncycastle", module = "bcprov-jdk18on")
        exclude(group = "org.bouncycastle", module = "bcpkix-jdk18on")
        exclude(group = "org.bouncycastle", module = "bcutil-jdk18on")
    }
    implementation("org.bouncycastle:bcprov-jdk18on:1.85")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.85")
    implementation("org.bouncycastle:bcutil-jdk18on:1.85")
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.zxing:core:3.5.3")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("org.mockito:mockito-core:5.23.0")
    testImplementation("org.json:json:20260814")

    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.08.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// ---------------------------------------------------------------------------
// Native payload: per-variant build + provenance verification
//
// Everything the Rust crates produce is generated into app/build/generated/:
// nothing is written into app/src, and `./gradlew clean` removes the lot.
//
//   build/generated/jniLibs/debug/<abi>/libclient.so    Cargo "dev" profile
//   build/generated/jniLibs/release/<abi>/libclient.so Cargo "release" profile
//   build/generated/assets/csqtt-linux-*               server binaries (release)
//   build/generated/provenance/*.json                  provenance manifests
//
// Debug and release clients are built from separate Cargo target directories, so
// switching build types can never mix artifacts, and each variant is wired to the
// merge task that actually packages it (merge<Variant>JniLibFolders / merge*Assets)
// rather than to preBuild - preBuild is shared by every variant and by the unit
// test tasks, which used to drag three Android ABIs and three musl server
// binaries into `./gradlew :app:test`.
//
// Each build task declares its real inputs and outputs, so Gradle skips Cargo when
// nothing Rust-related changed; the verify tasks stay unconditional, so a payload
// that does not match its manifest still fails the build.
//
// Every task keeps its property lookups inside its own configuration block:
// lambdas capturing script-level values cannot be stored in the configuration
// cache.
//
// Properties:
//   -Pcsqtt.abis=LIST                    ABIs to build and package
//   -Pcsqtt.cargoJobs=N                  cargo jobs per ABI (client)
//   -Pcsqtt.nativeTests=true             run fmt/clippy/test before building
//   -Pcsqtt.buildNativeClient=false      verify the client instead of rebuilding it
//   -Pcsqtt.buildNativeServer=false      verify the server assets instead of rebuilding them
//   -Pcsqtt.skipNativeVerification=true  skip both building and verification
// ---------------------------------------------------------------------------

// Plain Files, not Providers: AGP refuses Provider instances in the legacy
// SourceSet API because it cannot tell generated (read-only) from static
// directories, and the merge tasks are wired explicitly below anyway.
val rustGeneratedDir: File = layout.buildDirectory.dir("generated").get().asFile
val rustAssetsDir: File = rustGeneratedDir.resolve("assets")
val rustProvenanceDir: File = rustGeneratedDir.resolve("provenance")

fun jniLibsDir(variant: String): File = rustGeneratedDir.resolve("jniLibs/$variant")
fun clientManifest(variant: String): File = rustProvenanceDir.resolve("libclient.$variant.json")

val rootBuildDir = rootProject.layout.projectDirectory.dir("build").asFile

// Provenance verifies the installed libraries against the intermediate Cargo
// output, which lives outside Gradle's output tree. If somebody deletes it, the
// build task must run again instead of being considered up to date.
fun clientCargoArtifacts(variant: String): List<File> = buildList {
    val profileDir = if (variant == "debug") "android-debug" else "release"
    selectedAbis.forEach { abi ->
        val (target, suffix) = when (abi) {
            "arm64-v8a" -> "aarch64-linux-android" to "arm64"
            "armeabi-v7a" -> "armv7-linux-androideabi" to "armv7"
            else -> "x86_64-linux-android" to "x86_64"
        }
        add(rootBuildDir.resolve("rust-client-android-$variant-$suffix/$target/$profileDir/client"))
    }
}

fun serverCargoArtifacts(): List<File> = listOf(
    "csqtt-linux-amd64" to "x86_64-unknown-linux-musl",
    "csqtt-linux-arm64" to "aarch64-unknown-linux-musl",
    "csqtt-linux-armv7" to "armv7-unknown-linux-musleabihf",
).map { (asset, target) ->
    rootBuildDir.resolve("csqtt-uring-linux-$asset/$target/release/csqtt")
}
fun capitalised(variant: String) = variant.replaceFirstChar { it.uppercaseChar() }

// Conservative superset of what the provenance scripts hash: a missed file here
// would mean Gradle skips a rebuild that provenance would then reject.
val clientNativeInputs = fileTree(rootProject.projectDir) {
    include(
        "rust-client/*.rs",
        "rust-client/*.sh",
        "rust-client/Cargo.toml",
        "rust-client/Cargo.lock",
        "rust-client/rust-toolchain.toml",
        // The provenance scripts hash every file under vendor/, so Gradle has to
        // watch all of them: a narrower glob would let a build task stay
        // UP-TO-DATE while verify rejects the manifest.
        "rust-client/vendor/**",
        "shared/*.rs",
        "domains.txt",
        // Cargo config: crate-local and any ancestor one, they set target/rustflags.
        ".cargo/config.toml",
        "rust-client/.cargo/**",
        "scripts/android_env.sh",
        "scripts/native_client_provenance.sh",
    )
}

val serverNativeInputs = fileTree(rootProject.projectDir) {
    include(
        "rust-server/*.rs",
        "rust-server/*.sh",
        "rust-server/*.json",
        // Selects the default target and the link flags, so a change here changes
        // the binary while every other declared input stays the same.
        ".cargo/config.toml",
        "rust-server/.cargo/**",
        "rust-server/Cargo.toml",
        "rust-server/Cargo.lock",
        "rust-server/rust-toolchain.toml",
        "shared/*.rs",
        "app/src/main/assets/domains.txt",
        "scripts/server_asset_provenance.sh",
    )
}

fun registerNativeClientBuild(variant: String) = tasks.register<Exec>("buildNativeClient${capitalised(variant)}") {
    val skip = (providers.gradleProperty("csqtt.skipNativeVerification").orNull ?: "false").toBoolean()
    val enabled = !skip && (providers.gradleProperty("csqtt.buildNativeClient").orNull ?: "true").toBoolean()
    val tests = (providers.gradleProperty("csqtt.nativeTests").orNull ?: "false").toBoolean()
    val jobs = providers.gradleProperty("csqtt.cargoJobs").orNull
        ?: (Runtime.getRuntime().availableProcessors() / 3).coerceAtLeast(1).toString()
    val abis = selectedAbis.joinToString(",")
    val sdk = androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath

    group = "build"
    description = "Builds the Rust client for Android ($variant, cargo-ndk) into build/generated/jniLibs/$variant."
    workingDir = rootProject.layout.projectDirectory.asFile
    environment("ANDROID_HOME", sdk)
    environment("ANDROID_SDK_ROOT", sdk)
    commandLine(
        "bash",
        "rust-client/build_so.sh",
        if (tests) "--tests" else "--no-tests",
        "--abis=$abis",
        "--jobs=$jobs",
        "--variant=$variant",
    )

    inputs.files(clientNativeInputs)
    inputs.property("variant", variant)
    inputs.property("abis", abis)
    inputs.property("nativeTests", tests)
    outputs.dir(jniLibsDir(variant))
    outputs.file(clientManifest(variant))
    // Resolved to a local list: a lambda capturing a script-level function
    // cannot be stored in the configuration cache.
    val cargoArtifacts = clientCargoArtifacts(variant)
    outputs.upToDateWhen { cargoArtifacts.all { it.isFile } }

    onlyIf("the Rust client build is disabled") { enabled }
}

fun registerNativeClientVerify(
    variant: String,
    buildTask: TaskProvider<Exec>,
) = tasks.register<Exec>("verifyNativeClient${capitalised(variant)}") {
    val skip = (providers.gradleProperty("csqtt.skipNativeVerification").orNull ?: "false").toBoolean()
    val abis = selectedAbis.joinToString(",")

    group = "verification"
    description = "Verifies the $variant client payload against build/generated/provenance/libclient.$variant.json."
    workingDir = rootProject.layout.projectDirectory.asFile
    commandLine(
        "bash",
        "scripts/native_client_provenance.sh",
        "verify",
        "--abis=$abis",
        "--variant=$variant",
    )
    onlyIf("native verification is not skipped") { !skip }
    dependsOn(buildTask)
    isIgnoreExitValue = true
    doLast {
        if (executionResult.get().exitValue != 0) {
            throw GradleException(
                "Native client payload ($variant) is missing or stale. " +
                    "Gradle builds it with rust-client/build_so.sh --variant=$variant; see the output above " +
                    "or run it manually with --no-tests."
            )
        }
    }
}

val buildNativeClientDebug = registerNativeClientBuild("debug")
val buildNativeClientRelease = registerNativeClientBuild("release")
val verifyNativeClientDebug = registerNativeClientVerify("debug", buildNativeClientDebug)
val verifyNativeClientRelease = registerNativeClientVerify("release", buildNativeClientRelease)

val buildNativeServer = tasks.register<Exec>("buildNativeServer") {
    val skip = (providers.gradleProperty("csqtt.skipNativeVerification").orNull ?: "false").toBoolean()
    val enabled = !skip && (providers.gradleProperty("csqtt.buildNativeServer").orNull ?: "true").toBoolean()
    val tests = (providers.gradleProperty("csqtt.nativeTests").orNull ?: "false").toBoolean()

    group = "build"
    description = "Builds the Rust server binaries (static musl) into build/generated/assets."
    workingDir = rootProject.layout.projectDirectory.asFile
    commandLine("bash", "rust-server/build_linux.sh", if (tests) "--tests" else "--no-tests")

    inputs.files(serverNativeInputs)
    inputs.property("nativeTests", tests)
    outputs.dir(rustAssetsDir)
    outputs.file(rustProvenanceDir.resolve("csqtt-server.json"))
    val cargoArtifacts = serverCargoArtifacts()
    outputs.upToDateWhen { cargoArtifacts.all { it.isFile } }

    onlyIf("the Rust server build is disabled") { enabled }
}

val verifyNativeServer = tasks.register<Exec>("verifyNativeServer") {
    val skip = (providers.gradleProperty("csqtt.skipNativeVerification").orNull ?: "false").toBoolean()

    group = "verification"
    description = "Verifies assets/csqtt-linux-* against build/generated/provenance/csqtt-server.json."
    workingDir = rootProject.layout.projectDirectory.asFile
    commandLine("bash", "scripts/server_asset_provenance.sh", "verify")
    onlyIf("native verification is not skipped") { !skip }
    dependsOn(buildNativeServer)
    isIgnoreExitValue = true
    doLast {
        if (executionResult.get().exitValue != 0) {
            throw GradleException(
                "Native server assets are missing or stale. Gradle builds them with rust-server/build_linux.sh; " +
                    "see the buildNativeServer output above or run it manually with --no-tests."
            )
        }
    }
}

// Generated native payload joins the variant that actually packages it.
android.sourceSets.getByName("main") {
    assets.directories.add(rustAssetsDir.absolutePath)
}
android.sourceSets.getByName("debug") {
    jniLibs.directories.add(jniLibsDir("debug").absolutePath)
}
android.sourceSets.getByName("release") {
    jniLibs.directories.add(jniLibsDir("release").absolutePath)
}

tasks.configureEach {
    when (name) {
        "mergeDebugJniLibFolders" -> dependsOn(verifyNativeClientDebug)
        "mergeReleaseJniLibFolders" -> dependsOn(verifyNativeClientRelease)
        "mergeDebugAssets", "mergeReleaseAssets" -> dependsOn(verifyNativeServer)
    }
}

// Writing into the source-set directories by hand means Gradle does not infer
// task dependencies for every consumer; lint reads those same directories when it
// builds its model, so wire it explicitly as well (the merge tasks are above).
tasks.configureEach {
    val taskName = name
    if (taskName.startsWith("lint") || taskName.contains("Lint", ignoreCase = true)) {
        dependsOn(verifyNativeServer)
        when {
            taskName.contains("Debug", ignoreCase = true) -> dependsOn(verifyNativeClientDebug)
            taskName.contains("Release", ignoreCase = true) -> dependsOn(verifyNativeClientRelease)
        }
    }
}

// Two obvious entry points for "put this build on the phone". They go through
// scripts/install_apk.sh instead of AGP's own installer on purpose: installing
// the baseline profile next to the APK switches ddmlib to the session installer,
// which streams the file through a shell session at ~130 KB/s on the test device
// while a plain push reaches 36 MB/s. A 24 MB APK then costs three minutes
// before the install even starts, and the long stream is fragile enough to lose
// the transport halfway. The script pushes the APK and lets `pm install` read it
// from /data/local/tmp, and the baseline profile is applied on first launch.
// The names start with "install", so the release-signing hook above applies to
// them on its own.
androidComponents {
    onVariants { variant ->
        val variantName = variant.name
        val capitalisedVariant = capitalised(variantName)
        if (capitalisedVariant !in setOf("Debug", "Release")) return@onVariants
        val applicationId = variant.applicationId

        tasks.register<Exec>("installCsqtt$capitalisedVariant") {
            group = "install"
            description = "Builds the $variantName variant and installs it on the connected device with adb."
            dependsOn(
                "assemble$capitalisedVariant",
                verifyNativeServer,
                if (variantName == "release") verifyNativeClientRelease else verifyNativeClientDebug,
            )
            workingDir = rootProject.layout.projectDirectory.asFile
            commandLine("bash", "scripts/install_apk.sh", "--variant", variantName)
            argumentProviders.add(
                CommandLineArgumentProvider { listOf("--application-id", applicationId.get()) }
            )
            // The device the ABI was taken from: install_apk.sh picks the
            // device itself otherwise, and with several devices connected it
            // would refuse to guess.
            deviceSerial?.let { environment("ANDROID_SERIAL", it) }
        }
    }
}

// Manual aggregate: verify both variants plus the server without packaging.
// Nothing depends on it, so Kotlin-only work never triggers a native build.
tasks.register("verifyNativeArtifacts") {
    group = "verification"
    description = "Verifies the debug and release client payloads plus the server assets."
    dependsOn(verifyNativeClientDebug, verifyNativeClientRelease, verifyNativeServer)
}
