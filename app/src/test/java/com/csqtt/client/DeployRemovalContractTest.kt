package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Source contract for removing the deploy feature from the app.
 *
 * The paths are resolved relative to the Gradle module directory first and to the
 * repository root second, matching the convention of [TvManifestTest]: unit tests may
 * run with either working directory.
 */
class DeployRemovalContractTest {
    private fun readModuleSource(relativePath: String): String =
        listOf(
            File("app/$relativePath"),
            File(relativePath),
        ).first(File::isFile).readText()

    private fun assertAbsent(fileName: String, source: String, vararg forbidden: String) {
        forbidden.forEach { token ->
            assertFalse("$fileName must not contain `$token`", source.contains(token))
        }
    }

    @Test
    fun `tunnel service has no deploy actions or preparation hook`() {
        assertAbsent(
            "TunnelService.kt",
            readModuleSource("src/main/java/com/csqtt/client/TunnelService.kt"),
            "DEPLOY_START",
            "DEPLOY_STOP",
            "DEPLOY_CANCEL",
            "prepareForDeploy",
        )
    }

    @Test
    fun `application does not initialise deploy manager`() {
        assertAbsent(
            "CsqttApplication.kt",
            readModuleSource("src/main/java/com/csqtt/client/CsqttApplication.kt"),
            "DeployManager",
        )
    }

    @Test
    fun `tunnel manager and logs tab have no deploy logging helpers`() {
        assertAbsent(
            "TunnelManager.kt",
            readModuleSource("src/main/java/com/csqtt/client/TunnelManager.kt"),
            "beginDeployLog",
            "addDeploy",
        )
        assertAbsent(
            "LogsTab.kt",
            readModuleSource("src/main/java/com/csqtt/client/ui/LogsTab.kt"),
            "beginDeployLog",
            "addDeploy",
        )
    }

    @Test
    fun `main activity has no deploy navigation`() {
        // The navigation index is intentionally not asserted: after Task 1 the logs tab
        // owns id 2, so a numeric check would be misleading.
        assertAbsent(
            "MainActivity.kt",
            readModuleSource("src/main/java/com/csqtt/client/MainActivity.kt"),
            "R.string.nav_deploy",
            "DeployTab",
            "deploySettings",
            "deploy:",
        )
    }
}
