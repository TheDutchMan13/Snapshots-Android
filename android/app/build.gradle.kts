import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.thedutchman13.snapshots"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.thedutchman13.snapshots"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release builds are signed with the key in android/key.properties (written by the GitHub
    // workflow from the repository's secrets). Every build must use the same key, or Android
    // refuses to install an update over the app. Without the file a release build stops, unless
    // SNAPSHOTS_DEBUG_SIGNING=1 asks for the debug key on purpose (a test APK that won't install
    // over a real one; the workflow does this when the repository has no key).
    val keyFile = rootProject.file("key.properties")
    val keys = Properties()
    if (keyFile.exists()) keyFile.inputStream().use { keys.load(it) }
    val debugSigning = System.getenv("SNAPSHOTS_DEBUG_SIGNING") == "1"
    val releaseWanted = gradle.startParameter.taskNames.any { it.endsWith("Release") }
    if (releaseWanted && !keyFile.exists() && !debugSigning) {
        throw GradleException(
            "No android/key.properties, so there is no key to sign the release build with. " +
                "Create it (see README.md), or set SNAPSHOTS_DEBUG_SIGNING=1 for a test build signed with the debug key."
        )
    }

    signingConfigs {
        if (keyFile.exists()) {
            create("release") {
                storeFile = file(keys.getProperty("storeFile"))
                storePassword = keys.getProperty("storePassword")
                keyAlias = keys.getProperty("keyAlias")
                keyPassword = keys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
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
