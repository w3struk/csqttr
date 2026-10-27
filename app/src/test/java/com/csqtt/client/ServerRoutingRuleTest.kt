package com.csqtt.client

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerRoutingRuleTest {
    @Test fun allEightModeCombinationsAreIndependent() {
        for (apps in listOf(false, true)) for (domains in listOf(false, true)) for (ips in listOf(false, true)) {
            val json = JSONObject().put("is_whitelist", apps).put("domains_is_whitelist", domains)
                .put("ip_is_whitelist", ips).put("packages", org.json.JSONArray(listOf("com.example.app")))
            val rule = requireNotNull(parseServerRoutingRule(json.toString()))
            assertEquals(apps, rule.isWhite)
            assertEquals(domains, rule.domainsIsWhite)
            assertEquals(ips, rule.ipIsWhite)
        }
    }

    @Test fun stringModesAndLegacyFallbackRemainSupported() {
        val modern = requireNotNull(parseServerRoutingRule("""{"mode":"whitelist","domains_mode":"blacklist","ip_mode":"whitelist"}"""))
        assertTrue(modern.isWhite)
        assertFalse(modern.domainsIsWhite)
        assertTrue(modern.ipIsWhite)
        val legacy = requireNotNull(parseServerRoutingRule("""{"mode":"whitelist"}"""))
        assertTrue(legacy.isWhite)
        assertTrue(legacy.domainsIsWhite)
    }

    @Test fun invalidPackagesDoNotBecomeAnEmptyDeviceWideRule() {
        for (entry in listOf("com.example app", "../bad", "com..example", "a".repeat(256))) {
            val json = JSONObject().put("packages", org.json.JSONArray(listOf(entry)))
            assertNull(parseServerRoutingRule(json.toString()))
        }
        assertNull(parseServerRoutingRule("""{"packages":[42]}"""))
        assertNull(parseServerRoutingRule("""{"packages":"com.example.app"}"""))
        assertTrue(isRoutingPackageName("android"))
        assertTrue(isRoutingPackageName("com.example_app.client2"))
    }

    @Test fun emptyListsAndDuplicatesAreHandledWithoutChangingMode() {
        val rule = requireNotNull(parseServerRoutingRule("""{"mode":"whitelist","packages":[" com.example.app ","com.example.app"]}"""))
        assertTrue(rule.isWhite)
        assertEquals(listOf("com.example.app"), rule.packages)
        assertTrue(requireNotNull(parseServerRoutingRule("{}" )).packages.isEmpty())
    }

    @Test fun presetFieldsAreParsedWhenPresent() {
        val rule = requireNotNull(
            parseServerRoutingRule("""{"preset_red":["ru.fns.lkfl"],"preset_orange":["ru.sberbankmobile"]}"""),
        )
        assertEquals(listOf("ru.fns.lkfl"), rule.presetRed)
        assertEquals(listOf("ru.sberbankmobile"), rule.presetOrange)
    }

    @Test fun missingPresetFieldsYieldEmptyLists() {
        val rule = requireNotNull(parseServerRoutingRule("""{"mode":"blacklist"}"""))
        assertEquals(emptyList<String>(), rule.presetRed)
        assertEquals(emptyList<String>(), rule.presetOrange)
    }

    @Test fun invalidPresetEntriesAreDroppedIndividually() {
        val rule = requireNotNull(
            parseServerRoutingRule(
                """{"preset_red":["com.good","bad pkg","com..x",42],"preset_orange":["com.good","com.good"]}""",
            ),
        )
        assertEquals(listOf("com.good"), rule.presetRed)
        assertEquals(listOf("com.good"), rule.presetOrange)
    }

    @Test fun invalidPresetDoesNotRejectTheWholeRule() {
        val rule = requireNotNull(
            parseServerRoutingRule("""{"packages":["com.example.app"],"preset_red":["totally broken"]}"""),
        )
        assertEquals(listOf("com.example.app"), rule.packages)
        assertEquals(emptyList<String>(), rule.presetRed)
    }

    @Test fun presetEntriesAreTrimmedAndDeduplicated() {
        val rule = requireNotNull(parseServerRoutingRule("""{"preset_red":[" com.a ","com.a",""]}"""))
        assertEquals(listOf("com.a"), rule.presetRed)
    }

    @Test fun presetArrayIsCappedAt4096Entries() {
        val entries = (0..4096).map { "com.example.app$it" }
        val rule = requireNotNull(parseServerRoutingRule(JSONObject().put("preset_red", org.json.JSONArray(entries)).toString()))
        assertEquals(4096, rule.presetRed.size)
    }

    @Test fun nonArrayPresetValueYieldsEmptyListAndValidRule() {
        val rule = requireNotNull(parseServerRoutingRule("""{"preset_red":"com.a"}"""))
        assertEquals(emptyList<String>(), rule.presetRed)
    }
}
