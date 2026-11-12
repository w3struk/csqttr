package com.csqtt.client

import com.csqtt.client.ui.utils.encryptCsqttPayload
import com.csqtt.client.VkHashValidationStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Единственный источник подключения — ссылка `csqtt://`. Ручной адрес сервера и пароль
 * удалены, поэтому без ссылки источника нет вовсе, а с валидной ссылкой адрес, порт и
 * пароль приходят только из неё.
 */
class ConnectionSourceTest {

    private fun enc(plain: String): String = "csqtt://" + encryptCsqttPayload(plain)

    @Test
    fun `missing link has no connection source`() {
        assertNull(resolveConnectionSourceFrom(link = null, hashes = null))
        assertNull(resolveConnectionSourceFrom(link = "", hashes = "abcdefghijklmnop1"))
        assertNull(resolveConnectionSourceFrom(link = "не-ссылка", hashes = null))
    }

    @Test
    fun `valid link produces a source with the password from the link`() {
        val link = enc("connect?v=2&host=203.0.113.7&peer=46000&password=client-pass")
        val source = resolveConnectionSourceFrom(link = link, hashes = null)

        assertNotNull(source)
        assertEquals("203.0.113.7:46000", source!!.peer)
        assertEquals("client-pass", source.password)
        assertEquals("", source.hashes)
        assertTrue(source.hashesFromLink.not())
        assertEquals("", source.vkAccessToken)
    }

    @Test
    fun `link hashes win over the stored fallback`() {
        val link = enc("connect?v=2&host=vps.example&peer=46000&hashes=abcdefghijklmnop1")
        val source = resolveConnectionSourceFrom(link = link, hashes = "zyxwvutsrqponmlk2")!!

        assertEquals("abcdefghijklmnop1", source.hashes)
        assertTrue(source.hashesFromLink)
    }

    @Test
    fun `stored hashes are used when the link carries no vk credentials`() {
        val link = enc("connect?v=2&host=vps.example&peer=46000")
        val source = resolveConnectionSourceFrom(link = link, hashes = " zyxwvutsrqponmlk2 , short ")!!

        assertEquals("zyxwvutsrqponmlk2", source.hashes)
        assertTrue(!source.hashesFromLink)
    }

    @Test
    fun `invalid hashes are filtered from link and stored fallback`() {
        val bad = "badhashbadhashbad1"
        val good = "goodhashgoodhash1"
        val invalid = mapOf(bad to VkHashValidationStatus.Invalid)
        val fromLink = resolveConnectionSourceFrom(
            link = enc("connect?v=2&host=vps.example&peer=46000&hashes=$bad,$good"),
            hashes = null,
            invalidHashes = invalid,
        )!!
        assertEquals(good, fromLink.hashes)
        assertTrue(fromLink.hashesFromLink)

        val fromStore = resolveConnectionSourceFrom(
            link = enc("connect?v=2&host=vps.example&peer=46000"),
            hashes = "$bad,$good",
            invalidHashes = invalid,
        )!!
        assertEquals(good, fromStore.hashes)
    }

    @Test
    fun `link token disables stored hashes`() {
        val link = enc("connect?v=2&host=vps.example&peer=46000&token=vk1.aBc-_%2B9")
        val source = resolveConnectionSourceFrom(link = link, hashes = "zyxwvutsrqponmlk2")!!

        assertEquals("", source.hashes)
        assertEquals("vk1.aBc-_+9", source.vkAccessToken)
        assertTrue(source.tokenFromLink)
    }
}
