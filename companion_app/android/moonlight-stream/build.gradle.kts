import java.io.File

plugins {
    id("com.android.library")
}

val vendorMoonlightRoot =
    file("../../../Vendor/streaming-repos/moonlight-android/app/src/main")
val moonlightCacheRoot =
    File(System.getProperty("user.home"), ".cache/gbear-moonlight-ndk")

tasks.register("syncMoonlightVendor") {
    doLast {
        val targets = listOf(
            "java" to vendorMoonlightRoot.resolve("java"),
            "res" to vendorMoonlightRoot.resolve("res"),
            "jni" to vendorMoonlightRoot.resolve("jni"),
        )
        for ((name, source) in targets) {
            if (!source.exists()) {
                throw GradleException(
                    "Missing Moonlight vendor tree at ${source.path}. " +
                        "Run Scripts/clone-streaming-forks.sh first.",
                )
            }
            val dest = moonlightCacheRoot.resolve(name)
            dest.deleteRecursively()
            source.copyRecursively(dest, overwrite = true)
        }
        val assetsSource = vendorMoonlightRoot.resolve("assets")
        val assetsDest = moonlightCacheRoot.resolve("assets")
        if (assetsSource.exists()) {
            assetsDest.deleteRecursively()
            assetsSource.copyRecursively(assetsDest, overwrite = true)
        } else {
            assetsDest.deleteRecursively()
        }

        patchAndroidCryptoProviderForModernAndroid(
            moonlightCacheRoot.resolve("java/com/limelight/binding/crypto/AndroidCryptoProvider.java"),
        )

        val patchScript = file("patch_moonlight_android.py")
        if (patchScript.exists()) {
            exec {
                commandLine("python3", patchScript.absolutePath, moonlightCacheRoot.resolve("java").absolutePath)
            }
        }

        logger.lifecycle("Synced Moonlight sources to ${moonlightCacheRoot.path}")
    }
}

/** Android P+ removed RSA KeyFactory from the BC provider; use the platform default. */
fun patchAndroidCryptoProviderForModernAndroid(cryptoProviderFile: File) {
    if (!cryptoProviderFile.exists()) return
    var text = cryptoProviderFile.readText()
    val certLoad = "CertificateFactory certFactory = CertificateFactory.getInstance(\"X.509\", bcProvider);"
    val certPatched = "CertificateFactory certFactory = CertificateFactory.getInstance(\"X.509\");"
    val keyLoad = "KeyFactory keyFactory = KeyFactory.getInstance(\"RSA\", bcProvider);"
    val keyPatched = "KeyFactory keyFactory = KeyFactory.getInstance(\"RSA\");"
    if (text.contains(certLoad)) {
        text = text.replace(certLoad, certPatched)
    }
    if (text.contains(keyLoad)) {
        text = text.replace(keyLoad, keyPatched)
    }
    cryptoProviderFile.writeText(text)
}

tasks.named("preBuild").configure {
    dependsOn("syncMoonlightVendor")
}

val nativeBuildRoot =
    File(System.getProperty("user.home"), ".cache/gbear-companion-native")

android {
    namespace = "com.limelight"
    compileSdk = 34
    ndkVersion = "27.0.12077973"

    defaultConfig {
        minSdk = 21
        buildConfigField("boolean", "ROOT_BUILD", "false")
        buildConfigField("String", "APPLICATION_ID", "\"com.funnybearapps.gbearcompanion\"")
        externalNativeBuild {
            ndkBuild {
                arguments(
                    "NDK_OUT=${nativeBuildRoot.resolve("ndk-out").absolutePath}",
                    "NDK_LIBS_OUT=${nativeBuildRoot.resolve("ndk-libs").absolutePath}",
                )
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    lint {
        disable += "MissingTranslation"
    }

    sourceSets {
        getByName("main") {
            java.setSrcDirs(
                listOf(
                    moonlightCacheRoot.resolve("java"),
                    file("gbear-support"),
                ),
            )
            res.setSrcDirs(listOf(moonlightCacheRoot.resolve("res")))
            assets.setSrcDirs(listOf(moonlightCacheRoot.resolve("assets")))
        }
    }

    externalNativeBuild {
        ndkBuild {
            path = moonlightCacheRoot.resolve("jni/Android.mk")
        }
    }
}

dependencies {
    implementation("org.bouncycastle:bcprov-jdk18on:1.77")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.77")
    implementation("org.jcodec:jcodec:0.2.5")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jmdns:jmdns:3.5.9")
    implementation("com.github.cgutman:ShieldControllerExtensions:1.0.1")
}
