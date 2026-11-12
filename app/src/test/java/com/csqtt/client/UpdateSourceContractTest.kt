package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Проверка источника обновлений: приложение обязано смотреть в наш репозиторий
 * (`w3struk/csqttr`), а не в апстрим. Иначе «Проверить обновления» предлагает
 * чужие релизы.
 */
class UpdateSourceContractTest {
    private val urls = listOf(
        CsqttConstants.Update.GITHUB_RELEASES_URL,
        CsqttConstants.Update.GITHUB_LATEST_RELEASE_URL,
        CsqttConstants.Update.GITHUB_LATEST_RELEASE_WEB_URL,
        CsqttConstants.Update.GITHUB_RELEASE_TAG_URL_PREFIX,
        CsqttConstants.Update.GITHUB_TAGS_URL,
        CsqttConstants.Update.GITHUB_TAG_TREE_URL_PREFIX,
        CsqttConstants.Links.RELEASES,
    )

    @Test
    fun updateUrlsPointToOurRepository() {
        urls.forEach { url ->
            assertTrue("URL должен вести в w3struk/csqttr: $url", url.contains("w3struk/csqttr"))
        }
    }

    @Test
    fun updateUrlsDoNotPointToUpstream() {
        urls.forEach { url ->
            assertFalse("URL не должен вести в amurcanov/csqtt: $url", url.contains("amurcanov/csqtt"))
        }
    }
}
