package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupDiagnosticPolicyTest {
    @Test
    fun noticeNeverAppearsBeforeTheRaisedThreshold() {
        assertNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                30_000L,
                0,
            )
        )
        assertNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                // Замер @debugger на деградировавшем DNS: креды пришли за ~90 с.
                // Это заведомо поздняя, но успешная загрузка — жалобы быть не должно.
                90_000L,
                0,
            )
        )
        assertNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS - 1L,
                0,
            )
        )
        assertNotNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS,
                0,
            )
        )
    }

    @Test
    fun thresholdSitsBetweenObservedSlowLoadAndClientBudget() {
        // Ниже наблюдаемой «поздкой, но успешной» загрузки (80–90 с на деградировавшем
        // DNS) — значит, не ругается зря.
        assertTrue(StartupDiagnosticPolicy.NOTICE_AFTER_MS > 90_000L)
        // Ниже собственного таймаута клиента (240 с) — значит, предупреждение не
        // успевает объявить проблемой то, что клиент ещё не посчитал неудачей.
        // 240_000 — ручное зеркало CREDENTIAL_FETCH_TIMEOUT из
        // rust-client/worker.rs: связки через код/генерацию тут нет (это правка
        // через границу языков), поэтому при изменении клиентского таймаута надо
        // пересмотреть и это число, и NOTICE_AFTER_MS.
        assertTrue(StartupDiagnosticPolicy.NOTICE_AFTER_MS < StartupDiagnosticPolicy.CLIENT_CREDENTIAL_BUDGET_MS)
        assertEquals(240_000L, StartupDiagnosticPolicy.CLIENT_CREDENTIAL_BUDGET_MS)
    }

    /**
     * Диагностика медленного старта — не ошибка: `isError = true` поднимал бы
     * `unreadErrorCount` и красил строку, хотя текст говорит «клиент продолжает
     * попытки».
     */
    @Test
    fun noticesAreNotErrors() {
        val stages = listOf(
            TunnelStartupStage.WAITING_FOR_CREDENTIALS,
            TunnelStartupStage.WAITING_FOR_TURN_OR_PEER,
        )
        for (stage in stages) {
            val notice = StartupDiagnosticPolicy.notice(
                stage,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS,
                0,
            )
            assertNotNull(notice)
            assertFalse("$stage", notice!!.isError)
            assertEquals(StartupDiagnosticPolicy.NOTICE_PRIORITY, notice.priority)
        }
    }

    @Test
    fun noticeKeysAreStableJournalKeys() {
        assertEquals(
            "startup_waiting_credentials",
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS,
                0,
            )!!.key,
        )
        assertEquals(
            "startup_waiting_turn",
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_TURN_OR_PEER,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS,
                0,
            )!!.key,
        )
        assertEquals(StartupDiagnosticPolicy.CREDENTIALS_KEY, "startup_waiting_credentials")
        assertEquals(StartupDiagnosticPolicy.TURN_KEY, "startup_waiting_turn")
    }

    @Test
    fun anonymousModesNeverBlameTokenOrCaptcha() {
        val modes = listOf(CsqttConstants.VkAuth.MODE_CALLS, CsqttConstants.VkAuth.MODE_AUTO_JS)
        for (mode in modes) {
            val message = StartupDiagnosticPolicy.credentialsMessage(mode)
            assertFalse("$mode не должен упоминать капчу", message.contains("капч", ignoreCase = true))
            assertFalse("$mode не должен упоминать токен", message.contains("токен", ignoreCase = true))
            assertFalse(message.contains("не выдал", ignoreCase = true))
            assertTrue(message.contains("соединен", ignoreCase = true))
        }
    }

    @Test
    fun legacyModeMayMentionCaptchaButNotTheUserToken() {
        val message = StartupDiagnosticPolicy.credentialsMessage(CsqttConstants.VkAuth.MODE_CAPTCHA)
        assertTrue(message.contains("капч", ignoreCase = true))
        assertFalse(message.contains("токен", ignoreCase = true))
        assertFalse(message.contains("не выдал", ignoreCase = true))
    }

    @Test
    fun unknownModeFallsBackToTheAnonymousWording() {
        for (mode in listOf(null, "", "не-известный-режим")) {
            val message = StartupDiagnosticPolicy.credentialsMessage(mode)
            assertFalse(message.contains("капч", ignoreCase = true))
            assertFalse(message.contains("токен", ignoreCase = true))
        }
    }

    @Test
    fun liveWorkersOrAReadyStageSilenceTheNotice() {
        assertNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.READY,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS * 5,
                0,
            )
        )
        assertNull(
            StartupDiagnosticPolicy.notice(
                TunnelStartupStage.WAITING_FOR_CREDENTIALS,
                CsqttConstants.VkAuth.MODE_CALLS,
                StartupDiagnosticPolicy.NOTICE_AFTER_MS * 5,
                3,
            )
        )
    }

    @Test
    fun credentialsNoticeKeepsItsJournalKeyAndPriority() {
        val notice = StartupDiagnosticPolicy.notice(
            TunnelStartupStage.WAITING_FOR_CREDENTIALS,
            CsqttConstants.VkAuth.MODE_CALLS,
            StartupDiagnosticPolicy.NOTICE_AFTER_MS,
            0,
        )
        assertNotNull(notice)
        assertEquals("startup_waiting_credentials", notice!!.key)
        assertEquals(98, notice.priority)
    }

    @Test
    fun turnNoticeReportsTheLayerThatActuallyStalled() {
        val notice = StartupDiagnosticPolicy.notice(
            TunnelStartupStage.WAITING_FOR_TURN_OR_PEER,
            CsqttConstants.VkAuth.MODE_CAPTCHA,
            StartupDiagnosticPolicy.NOTICE_AFTER_MS,
            0,
        )
        assertNotNull(notice)
        assertEquals("startup_waiting_turn", notice!!.key)
        // Креды уже получены — капча и токен здесь ни при чём.
        assertFalse(notice.message.contains("капч", ignoreCase = true))
        assertFalse(notice.message.contains("токен", ignoreCase = true))
        assertTrue(notice.message.contains("креды получены", ignoreCase = true))
    }

    @Test
    fun noticesAreDiagnosticsNotAccusations() {
        val stages = listOf(
            TunnelStartupStage.WAITING_FOR_CREDENTIALS,
            TunnelStartupStage.WAITING_FOR_TURN_OR_PEER,
        )
        val modes = listOf(
            CsqttConstants.VkAuth.MODE_CALLS,
            CsqttConstants.VkAuth.MODE_CAPTCHA,
            CsqttConstants.VkAuth.MODE_AUTO_JS,
        )
        for (stage in stages) {
            for (mode in modes) {
                val notice = StartupDiagnosticPolicy.notice(
                    stage,
                    mode,
                    StartupDiagnosticPolicy.NOTICE_AFTER_MS,
                    0,
                )
                assertNotNull("$stage / $mode", notice)
                val message = notice!!.message
                assertTrue(message, message.startsWith("[ДИАГНОСТИКА]"))
                // Ни «VK не выдал», ни «прервано»: клиент ещё продолжает попытки.
                assertFalse(message, message.contains("не выдал", ignoreCase = true))
                assertFalse(message, message.contains("прерван", ignoreCase = true))
                assertTrue(message, message.contains("попытк", ignoreCase = true))
            }
        }
    }
}
