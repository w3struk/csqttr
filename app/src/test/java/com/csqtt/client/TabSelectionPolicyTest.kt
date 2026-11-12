package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Test

class TabSelectionPolicyTest {
    @Test
    fun `out of range saved tab resets to connection`() {
        assertEquals(0, resolveSelectedTab(4, listOf(0, 1, 2, 3)))
    }

    @Test
    fun `saved logs tab stays on logs`() {
        assertEquals(2, resolveSelectedTab(2, listOf(0, 1, 2, 3)))
    }

    @Test
    fun `hidden logs tab resets to connection`() {
        assertEquals(0, resolveSelectedTab(2, listOf(0, 1, 3)))
    }

    @Test
    fun `allowed tab is preserved`() {
        assertEquals(3, resolveSelectedTab(3, listOf(0, 1, 3)))
    }
}
