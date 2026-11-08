package com.csqtt.client.ui

import java.io.IOException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DeployResultPolicyTest {
    @Test
    fun exactMarkerAndZeroExitAreRequired() {
        assertTrue(isSuccessfulDeployResult(0, "done\nCSQTT_DEPLOY_OK\n"))
        assertFalse(isSuccessfulDeployResult(1, "CSQTT_DEPLOY_OK"))
        assertFalse(isSuccessfulDeployResult(0, "service is active"))
        assertFalse(isSuccessfulDeployResult(0, "prefix CSQTT_DEPLOY_OK suffix"))
    }

    @Test
    fun deployRollbackExitIsExplainedWithoutPretendingSuccess() {
        assertEquals(
            "Новый релиз не прошёл проверку; предыдущая установка восстановлена",
            deployFailureMessage(30, "CSQTT_DEPLOY_ROLLED_BACK\n"),
        )
        assertEquals(
            "Новый релиз не запустился, а автоматический rollback завершился с ошибкой — требуется проверка VPS",
            deployFailureMessage(31, "CSQTT_DEPLOY_ROLLBACK_FAILED\n"),
        )
    }

    @Test
    fun rollbackKeepsConcreteServerReason() {
        assertEquals(
            "Новый релиз не прошёл проверку; предыдущая установка восстановлена " +
                "Причина: Проверенный candidate-бинарник исчез после остановки старого runtime",
            deployFailureMessage(
                30,
                "CSQTT_DEPLOY_ERROR|cutover|Проверенный candidate-бинарник исчез после остановки старого runtime\n" +
                    "CSQTT_DEPLOY_ROLLED_BACK\n",
            ),
        )
    }

    @Test
    fun preflightFailureExplainsThatLiveServiceWasNotStopped() {
        assertEquals(
            "Кандидат не прошёл предзапусковую проверку; работающий сервер не останавливался",
            deployFailureMessage(20, "probe failed"),
        )
    }

    @Test
    fun authFailureHasActionableMessage() {
        assertEquals(
            "SSH-аутентификация отклонена: проверьте логин, пароль и разрешение PasswordAuthentication на VPS",
            friendlyDeployError("Auth fail for methods 'publickey,password'"),
        )
    }

    @Test
    fun publicKeyFailureHasKeySpecificMessage() {
        assertTrue(
            friendlyDeployError("Auth fail (public key): rejected")
                .contains("authorized_keys"),
        )
    }

    @Test
    fun timeoutHasShortMessage() {
        assertEquals("Истекло время ожидания SSH/SFTP", friendlyDeployError("connect timeout"))
    }

    @Test
    fun exhaustedUploadHasNetworkSpecificMessage() {
        assertTrue(
            friendlyDeployError("SFTP/SCP upload failed for csqtt: SFTP: channel closed")
                .contains("автоматического переподключения"),
        )
    }

    @Test
    fun serverSuccessLineBecomesCleanOkLog() {
        assertEquals(
            DeployOutputLine("csqtt установлен", DeployOutputLevel.OK),
            parseDeployOutputLine("✓ csqtt установлен"),
        )
    }

    @Test
    fun serverStepHasNoEmojiOrStatusSticker() {
        assertEquals(
            DeployOutputLine("Установка csqtt...", DeployOutputLevel.LOG),
            parseDeployOutputLine("📦 Установка csqtt..."),
        )
        assertEquals(
            DeployOutputLine("Проверка зависимостей", DeployOutputLevel.LOG),
            parseDeployOutputLine("[►] Проверка зависимостей"),
        )
    }

    @Test
    fun serverFailureBecomesErrorLog() {
        assertEquals(
            DeployOutputLine("Сервис csqtt не запустился", DeployOutputLevel.ERR),
            parseDeployOutputLine("[✗] Сервис csqtt не запустился"),
        )
    }

    @Test
    fun protocolAndDecorationLinesAreHidden() {
        assertNull(parseDeployOutputLine("CSQTT_PROGRESS|0.6|Бинарник..."))
        assertNull(parseDeployOutputLine("CSQTT_DEPLOY_ERROR|cutover|candidate disappeared"))
        assertNull(parseDeployOutputLine("════════════════════════════"))
        assertNull(parseDeployOutputLine("CSQTT_DEPLOY_OK"))
        assertNull(parseDeployOutputLine("CSQTT_DEPLOY_ROLLED_BACK"))
        assertNull(parseDeployOutputLine("CSQTT_DEPLOY_ROLLBACK_FAILED"))
    }

    @Test
    fun dockerModeUsesRawEnvironmentValues() {
        assertEquals("docker", deployMode(true))
        assertEquals("systemd", deployMode(false))
        assertEquals("a b#$\"\\c  d", deployEnvironmentValue("a b#$\"\\c\r\nd", true))
        assertEquals("\"a b#$\\\"\\\\c  d\"", deployEnvironmentValue("a b#$\"\\c\r\nd", false))
    }

    @Test
    fun serverAssetMatchesTheRemoteVpsArchitecture() {
        val outputs = listOf(
            "x86_64\n",
            "amd64\n",
            " \n\tX86_64 \t\narm64\n",
            " \n\tAmD64 \t\nriscv64\n",
        )
        for (output in outputs) {
            val architecture = serverArchitectureForMachine(output)
            assertEquals(ServerArchitecture.AMD64, architecture)
            assertEquals("csqtt-linux-amd64", architecture.assetName)
        }
    }

    @Test
    fun armRemoteVpsArchitecturesAreRejectedWithAmd64OnlyHint() {
        for (machine in listOf("aarch64", "arm64", "armv7l", "armv7", "armhf")) {
            val error = assertThrows("$machine не должен приниматься", IOException::class.java) {
                serverArchitectureForMachine("$machine\n")
            }
            assertTrue(
                "$machine: отказ должен объяснять поддерживаемую архитектуру",
                error.message.orEmpty().contains("Поддерживается только x86_64/amd64"),
            )
        }
    }

    @Test
    fun unsupportedRemoteVpsArchitectureHasAmd64OnlyHint() {
        val error = assertThrows(IOException::class.java) {
            serverArchitectureForMachine("riscv64\n")
        }
        assertTrue(error.message.orEmpty().contains("Поддерживается только x86_64/amd64"))
    }

    @Test
    fun emptyRemoteVpsArchitectureKeepsMissingUnameMessage() {
        for (output in listOf("", " \n\t")) {
            val error = assertThrows(IOException::class.java) {
                serverArchitectureForMachine(output)
            }
            assertEquals("VPS не вернул архитектуру через uname -m", error.message)
        }
    }

    @Test
    fun sshPasswordKeepsSpacesAndSpecialCharactersExactly() {
        assertEquals(
            "a !@#$%^&*()[]{};:,.?/\\|~+= b",
            sanitizeSshPassword("a !@#$%^&*()[]{};:,.?/\\|~+= b"),
        )
        assertEquals("pa ssword", sanitizeSshPassword("pa\n ss\rword"))
    }
}
