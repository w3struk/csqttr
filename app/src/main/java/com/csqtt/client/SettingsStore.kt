package com.csqtt.client

import android.content.Context
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

private fun <T> Flow<T>.onIo(): Flow<T> = flowOn(Dispatchers.IO)

internal data class TunnelAuthSnapshot(
    val profile: Int = -1,
    val csqttLink: String = "",
) {
    val isLoaded: Boolean
        get() = profile >= 0
}

class SettingsStore(context: Context) {
    private val appContext = context.applicationContext
    companion object {
        private val Context.dataStore by preferencesDataStore("settings")
        private val ACTIVE_PROFILE = intPreferencesKey("active_profile")
        private val SHOW_SYSTEM_APPS = booleanPreferencesKey("show_system_apps")
        private val CSQTT_LINK = stringPreferencesKey("csqtt_link")
        private val PARTICIPANT_SHOW_LOGS = booleanPreferencesKey("participant_show_logs")

        private val VK_HASHES = stringPreferencesKey("vk_hashes")
        private val SECONDARY_VK_HASH = stringPreferencesKey("secondary_vk_hash")
        private val WORKERS_PER_HASH = intPreferencesKey("workers_per_hash")
        private val PROTOCOL = stringPreferencesKey("protocol")
        private val LISTEN_PORT = intPreferencesKey("listen_port")
        private val SNI = stringPreferencesKey("sni")
        private val NO_DNS = booleanPreferencesKey("no_dns")
        private val CUSTOM_TURN_IPS = stringPreferencesKey("custom_turn_ips")
        private val SELECTED_TURN_SUBNET = stringPreferencesKey("selected_turn_subnet")
        private val TURN_SUBNET_IP_LIMIT = stringPreferencesKey("turn_subnet_ip_limit")

        private val USER_AGENT = stringPreferencesKey("user_agent")
        private val PROFILE_NAME = stringPreferencesKey("profile_name")

        private val EXCLUDED_APPS = stringPreferencesKey("excluded_apps")
        private val WHITELIST_APPS = stringPreferencesKey("whitelist_apps")
        // Глобальный, а не профильный ключ: пресет приходит с серверного правила и к профилям
        // отношения не имеет, поэтому через getProfileKey он не проходит.
        private val ORANGE_TUNNEL_ENABLED = stringPreferencesKey("orange_tunnel_enabled")

        private val PROXY_MODE = stringPreferencesKey("proxy_mode") 
        private val PROXY_HOST = stringPreferencesKey("proxy_host")
        private val PROXY_PORT = intPreferencesKey("proxy_port")

        private val VK_AUTH_MODE = stringPreferencesKey("vk_auth_mode") 
        private val OBFS_MODE = stringPreferencesKey("obfs_mode") 
        private val TURN_TRANSPORT = stringPreferencesKey("turn_transport")
        private val SRTP_MODE = stringPreferencesKey("srtp_mode")
        private val CAPTCHA_MODE = stringPreferencesKey("captcha_mode")
        private val CAPTCHA_SOLVE_METHOD = stringPreferencesKey("captcha_solve_method") 
        private val CAPTCHA_WBV_SOLVE_METHOD = stringPreferencesKey("captcha_wbv_solve_method") 

        private val VK_HASH_MODE = stringPreferencesKey("vk_hash_mode")
        private val VK_ACCESS_TOKEN = stringPreferencesKey("vk_access_token")
        private val VK_ACCESS_TOKEN_ENCRYPTED = stringPreferencesKey("vk_access_token_encrypted")
        private val VK_ACCESS_TOKEN_USER_ID = stringPreferencesKey("vk_access_token_user_id")

        private val IS_WHITELIST = booleanPreferencesKey("is_whitelist")
        private val SPLIT_TUNNEL_WHITELIST_MIGRATED = booleanPreferencesKey("split_tunnel_whitelist_migrated")
        private val SPLIT_TUNNEL_INVERTED_LIST_REPAIRED =
            booleanPreferencesKey("split_tunnel_inverted_list_repaired")
        private val EXTRA_WORKERS = booleanPreferencesKey("extra_workers")
        private val AUTO_JS_RISK_ACKNOWLEDGED = booleanPreferencesKey("auto_js_risk_acknowledged")
        private val TCP_TRANSPORT_RISK_ACKNOWLEDGED = booleanPreferencesKey("tcp_transport_risk_acknowledged")
        private val BATTERY_OPTIMIZATION_PROMPT_HANDLED =
            booleanPreferencesKey("battery_optimization_prompt_handled")
        private val AUTO_PAUSE_ON_WIFI = booleanPreferencesKey("auto_pause_on_wifi")
        private val THEME_MODE = stringPreferencesKey("theme_mode") 
        private val IS_DYNAMIC_COLOR = booleanPreferencesKey("is_dynamic_color")
        private val THEME_PALETTE = stringPreferencesKey("theme_palette")

        private val SELECTED_FINGERPRINT = stringPreferencesKey("selected_fingerprint")
        private val ACTIVE_CLIENT_IDS = stringPreferencesKey("active_client_ids")

        private val UPDATE_LAST_CHECK_AT = longPreferencesKey("update_last_check_at")
        private val UPDATE_LATEST_VERSION = stringPreferencesKey("update_latest_version")
        private val UPDATE_LAST_ERROR = stringPreferencesKey("update_last_error")
        private val UPDATE_CHECK_INTERVAL_HOURS = intPreferencesKey("update_check_interval_hours")
        private val UPDATE_POSTPONE_UNTIL = longPreferencesKey("update_postpone_until")
        private val UPDATE_POSTPONE_VERSION = stringPreferencesKey("update_postpone_version")
        private val UPDATE_DIALOG_LAST_SHOWN_VERSION = stringPreferencesKey("update_dialog_last_shown_version")
        private val UPDATE_DIALOG_LAST_SHOWN_AT = longPreferencesKey("update_dialog_last_shown_at")
        private val UPDATE_DIALOG_LAST_ACTION_VERSION = stringPreferencesKey("update_dialog_last_action_version")
        private val UPDATE_DIALOG_LAST_ACTION = stringPreferencesKey("update_dialog_last_action")
        private val UPDATE_DIALOG_LAST_ACTION_AT = longPreferencesKey("update_dialog_last_action_at")

        private val CLIENT_ID_CHECK_RESULTS = stringPreferencesKey("client_id_check_results")
        private val VK_HASH_CHECK_RESULTS = stringPreferencesKey("vk_hash_check_results")
        private val CONNECTION_GENERATION = longPreferencesKey("connection_generation")
        private val TUNNEL_LAST_DIAGNOSTIC = stringPreferencesKey("tunnel_last_diagnostic")
        private val TUNNEL_LAST_DIAGNOSTIC_AT = longPreferencesKey("tunnel_last_diagnostic_at")
        private val TUNNEL_WAS_RUNNING = booleanPreferencesKey("tunnel_was_running")

        @Volatile
        internal var cachedVkHashMode: String? = null

        @Volatile
        internal var cachedVkAccessToken: String? = null

        @Volatile
        internal var cachedObfsMode: String? = null

        @Volatile
        internal var cachedTurnTransport: String? = null

        @Volatile
        internal var cachedSrtpMode: String? = null

        @Volatile
        internal var cachedWorkersPerHash: Int? = null

        @Volatile
        internal var cachedExtraWorkers: Boolean? = null

        @Volatile
        internal var cachedCustomTurnIps: String? = null

        @Volatile
        internal var cachedExcludedApps: String? = null

        @Volatile
        internal var cachedWhitelistApps: String? = null

        @Volatile
        internal var cachedIsWhitelist: Boolean? = null

        @Volatile
        internal var cachedShowSystemApps: Boolean? = null

        @Volatile
        internal var cachedOrangeTunnelEnabled: String? = null

        private val uiCacheStarted = java.util.concurrent.atomic.AtomicBoolean(false)
        private val migrationsStarted = java.util.concurrent.atomic.AtomicBoolean(false)

        private fun <T> getProfileKey(baseKey: Preferences.Key<T>, profile: Int): Preferences.Key<T> {
            if (profile == 0) return baseKey
            val newName = "${baseKey.name}_$profile"
            @Suppress("UNCHECKED_CAST")
            return when (baseKey) {
                VK_HASHES, SECONDARY_VK_HASH, PROTOCOL, SNI, USER_AGENT, EXCLUDED_APPS, WHITELIST_APPS, PROXY_MODE, PROXY_HOST, VK_AUTH_MODE, OBFS_MODE, TURN_TRANSPORT, SRTP_MODE, CAPTCHA_MODE, CAPTCHA_SOLVE_METHOD, CAPTCHA_WBV_SOLVE_METHOD, CSQTT_LINK, SELECTED_FINGERPRINT, ACTIVE_CLIENT_IDS, VK_HASH_MODE, VK_ACCESS_TOKEN, VK_ACCESS_TOKEN_ENCRYPTED, VK_ACCESS_TOKEN_USER_ID, VK_HASH_CHECK_RESULTS, CLIENT_ID_CHECK_RESULTS, CUSTOM_TURN_IPS, SELECTED_TURN_SUBNET -> stringPreferencesKey(newName) as Preferences.Key<T>
                WORKERS_PER_HASH, LISTEN_PORT, PROXY_PORT -> intPreferencesKey(newName) as Preferences.Key<T>
                NO_DNS, IS_WHITELIST, EXTRA_WORKERS, SPLIT_TUNNEL_WHITELIST_MIGRATED -> booleanPreferencesKey(newName) as Preferences.Key<T>
                CONNECTION_GENERATION -> longPreferencesKey(newName) as Preferences.Key<T>
                else -> stringPreferencesKey(newName) as Preferences.Key<T>
            }
        }
    }

    private val dataStore = appContext.dataStore
    private val secureStore = SecureStringStore(appContext)

    val activeProfile: Flow<Int> = dataStore.data.map {
        (it[ACTIVE_PROFILE] ?: CsqttConstants.Profiles.MIN_INDEX).coerceIn(
            CsqttConstants.Profiles.MIN_INDEX,
            CsqttConstants.Profiles.MAX_INDEX,
        )
    }
    val tunnelLastDiagnostic: Flow<String> = dataStore.data.map {
        it[TUNNEL_LAST_DIAGNOSTIC] ?: ""
    }
    val showSystemApps: Flow<Boolean> = dataStore.data.map { it[SHOW_SYSTEM_APPS] ?: false }
    val orangeTunnelEnabled: Flow<String> = dataStore.data.map { it[ORANGE_TUNNEL_ENABLED] ?: "" }
    val csqttLink: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(CSQTT_LINK, profile)] ?: ""
    }
    val participantShowLogs: Flow<Boolean> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(PARTICIPANT_SHOW_LOGS, profile)] ?: false
    }

    val vkHashes: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(VK_HASHES, profile)] ?: ""
    }
    val secondaryVkHash: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(SECONDARY_VK_HASH, profile)] ?: ""
    }
    val workersPerHash: Flow<Int> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        val isExtra = prefs[getProfileKey(EXTRA_WORKERS, profile)] ?: false
        val max = WorkerCountPolicy.defaultMaximum(isExtra)
        val current = prefs[getProfileKey(WORKERS_PER_HASH, profile)] ?: 18
        WorkerCountPolicy.normalize(current, maximum = max)
    }
    val protocol: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(PROTOCOL, profile)] ?: "udp"
    }
    val listenPort: Flow<Int> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(LISTEN_PORT, profile)] ?: 0
    }
    val sni: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(SNI, profile)] ?: ""
    }

    internal val tunnelAuthSnapshot: Flow<TunnelAuthSnapshot> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        TunnelAuthSnapshot(
            profile = profile,
            csqttLink = prefs[getProfileKey(CSQTT_LINK, profile)] ?: "",
        )
    }.onIo()
    val excludedApps: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(EXCLUDED_APPS, profile)] ?: ""
    }
    val whitelistApps: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(WHITELIST_APPS, profile)] ?: ""
    }

    val vkAuthMode: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        when (prefs[getProfileKey(VK_AUTH_MODE, profile)]) {
            CsqttConstants.VkAuth.MODE_CAPTCHA -> CsqttConstants.VkAuth.MODE_CAPTCHA
            CsqttConstants.VkAuth.MODE_AUTO_JS -> CsqttConstants.VkAuth.MODE_AUTO_JS
            else -> CsqttConstants.VkAuth.MODE_CALLS
        }
    }
    val obfsMode: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        val mode = prefs[getProfileKey(OBFS_MODE, profile)]
        if (mode == "unified") {
            mode
        } else {
            CsqttConstants.Tunnel.DEFAULT_OBFS_MODE
        }
    }

    val turnTransport: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        when (prefs[getProfileKey(TURN_TRANSPORT, profile)]) {
            CsqttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS -> CsqttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS
            else -> CsqttConstants.Tunnel.DEFAULT_TURN_TRANSPORT
        }
    }

    val srtpMode: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        when (prefs[getProfileKey(SRTP_MODE, profile)]) {
            CsqttConstants.SrtpMode.WRAP -> CsqttConstants.SrtpMode.WRAP
            CsqttConstants.SrtpMode.DTLS -> CsqttConstants.SrtpMode.DTLS
            else -> CsqttConstants.SrtpMode.DEFAULT
        }
    }

    val customTurnIps: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        val subnetId = prefs[getProfileKey(SELECTED_TURN_SUBNET, profile)] ?: ""
        if (subnetId.isNotBlank()) {
            val stored = prefs[getProfileKey(CUSTOM_TURN_IPS, profile)]
            if (!stored.isNullOrBlank()) {
                stored
            } else {
                TurnSubnetRegistry.getJoinedIpsForSubnet(subnetId)
            }
        } else {
            ""
        }
    }

    val selectedTurnSubnet: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(SELECTED_TURN_SUBNET, profile)] ?: ""
    }

    val turnSubnetIpLimit: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(TURN_SUBNET_IP_LIMIT, profile)] ?: "ALL"
    }

    val captchaMode: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(CAPTCHA_MODE, profile)] ?: "auto"
    }
    val captchaSolveMethod: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(CAPTCHA_SOLVE_METHOD, profile)] ?: "auto"
    }
    val captchaWbvSolveMethod: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(CAPTCHA_WBV_SOLVE_METHOD, profile)] ?: "auto"
    }

    val vkHashMode: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        val mode = prefs[getProfileKey(VK_HASH_MODE, profile)]
        when (mode) {
            "auto", CsqttConstants.VkAutoHash.MODE_AUTO_API ->
                CsqttConstants.VkAutoHash.MODE_AUTO_API
            CsqttConstants.VkAutoHash.MODE_AUTO_JS ->
                CsqttConstants.VkAutoHash.MODE_AUTO_JS
            else -> CsqttConstants.VkAutoHash.MODE_MANUAL
        }
    }
    val vkAccessToken: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        readSecret(prefs, VK_ACCESS_TOKEN_ENCRYPTED, VK_ACCESS_TOKEN, profile)
    }.onIo()
    val vkAccessTokenUserId: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(VK_ACCESS_TOKEN_USER_ID, profile)] ?: ""
    }

    val isWhitelist: Flow<Boolean> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(IS_WHITELIST, profile)] ?: false
    }

    val profileNames: Flow<Map<Int, String>> = dataStore.data.map { prefs ->
        (CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX).associateWith { p ->
            val name = prefs[getProfileKey(PROFILE_NAME, p)]
            if (name.isNullOrBlank()) "Профиль $p" else name
        }
    }

    suspend fun saveProfileName(profile: Int, name: String) {
        dataStore.edit { prefs ->
            val trimmed = name.trim()
            if (trimmed.isEmpty() || trimmed == "Профиль $profile") {
                prefs.remove(getProfileKey(PROFILE_NAME, profile))
            } else {
                prefs[getProfileKey(PROFILE_NAME, profile)] = trimmed
            }
        }
    }

    val extraWorkers: Flow<Boolean> = kotlinx.coroutines.flow.flowOf(false)
    val autoJsRiskAcknowledged: Flow<Boolean> = dataStore.data.map { prefs ->
        prefs[AUTO_JS_RISK_ACKNOWLEDGED] ?: false
    }
    val tcpTransportRiskAcknowledged: Flow<Boolean> = dataStore.data.map { prefs ->
        prefs[TCP_TRANSPORT_RISK_ACKNOWLEDGED] ?: false
    }
    val autoPauseOnWifi: Flow<Boolean> = dataStore.data.map { prefs ->
        prefs[AUTO_PAUSE_ON_WIFI] ?: false
    }
    suspend fun isBatteryOptimizationPromptHandled(): Boolean =
        dataStore.data.first()[BATTERY_OPTIMIZATION_PROMPT_HANDLED] ?: false

    val themeMode: Flow<String> = dataStore.data.map { it[THEME_MODE] ?: "system" }
    val isDynamicColor: Flow<Boolean> = dataStore.data.map { it[IS_DYNAMIC_COLOR] ?: false }
    val themePalette: Flow<String> = dataStore.data.map { it[THEME_PALETTE] ?: "indigo" }

    val selectedFingerprint: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(SELECTED_FINGERPRINT, profile)] ?: "firefox"
    }
    val activeClientIds: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(ACTIVE_CLIENT_IDS, profile)] ?: CsqttConstants.Tunnel.DEFAULT_CLIENT_IDS
    }
    val clientIdCheckResults: Flow<String> = dataStore.data.map { prefs ->
        prefs[CLIENT_ID_CHECK_RESULTS] ?: "{}"
    }
    val vkHashCheckResults: Flow<String> = dataStore.data.map { prefs ->
        val profile = prefs[ACTIVE_PROFILE] ?: 0
        prefs[getProfileKey(VK_HASH_CHECK_RESULTS, profile)] ?: "{}"
    }
    val connectionGeneration: Flow<Long> = dataStore.data.map { prefs ->
        prefs[CONNECTION_GENERATION] ?: 0L
    }

    val tunnelWasRunning: Flow<Boolean> = dataStore.data.map { it[TUNNEL_WAS_RUNNING] ?: false }
    val updateLastCheckAt: Flow<Long> = dataStore.data.map { it[UPDATE_LAST_CHECK_AT] ?: 0L }
    val updateLatestVersion: Flow<String> = dataStore.data.map { it[UPDATE_LATEST_VERSION] ?: "" }
    val updateLastError: Flow<String> = dataStore.data.map { it[UPDATE_LAST_ERROR] ?: "" }
    val updateCheckIntervalHours: Flow<Int> = dataStore.data.map { it[UPDATE_CHECK_INTERVAL_HOURS] ?: 24 }
    val updatePostponeUntil: Flow<Long> = dataStore.data.map { it[UPDATE_POSTPONE_UNTIL] ?: 0L }
    val updatePostponeVersion: Flow<String> = dataStore.data.map { it[UPDATE_POSTPONE_VERSION] ?: "" }

    // Последним в классе, после всех свойств: Kotlin присваивает их сверху вниз, а сборщики
    // ниже стартуют на других потоках сразу. Выше flow'ов, которые они читают, сборщик успевал
    // прочитать null и вызвать collect на null — приложение падало при запуске и при рестарте
    // сервиса. Порядок объявления здесь единственное, что удерживает кэш от гонки.
    init {
        if (migrationsStarted.compareAndSet(false, true)) {
            CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
                migrateLegacyWhitelistMode()
                repairInvertedLocalBlacklist()
            }
        }
        if (uiCacheStarted.compareAndSet(false, true)) {
            CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
                launch {
                    dataStore.edit { prefs ->
                        for (p in CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX) {
                            prefs[getProfileKey(EXTRA_WORKERS, p)] = false
                        }
                    }
                }
                launch { vkHashMode.collect { cachedVkHashMode = it } }
                launch { vkAccessToken.collect { cachedVkAccessToken = it } }
                launch { obfsMode.collect { cachedObfsMode = it } }
                launch { turnTransport.collect { cachedTurnTransport = it } }
                launch { srtpMode.collect { cachedSrtpMode = it } }
                launch { workersPerHash.collect { cachedWorkersPerHash = it } }
                cachedExtraWorkers = false
                launch { customTurnIps.collect { cachedCustomTurnIps = it } }
                launch { excludedApps.collect { cachedExcludedApps = it } }
                launch { whitelistApps.collect { cachedWhitelistApps = it } }
                launch { isWhitelist.collect { cachedIsWhitelist = it } }
                launch { showSystemApps.collect { cachedShowSystemApps = it } }
                launch { orangeTunnelEnabled.collect { cachedOrangeTunnelEnabled = it } }
            }
        }
    }


    suspend fun saveTunnelWasRunning(running: Boolean) {
        dataStore.edit { prefs ->
            prefs[TUNNEL_WAS_RUNNING] = running
        }
    }

    suspend fun saveThemeMode(mode: String) {
        dataStore.edit { prefs ->
            prefs[THEME_MODE] = mode
        }
    }

    suspend fun saveDynamicColor(enabled: Boolean) {
        dataStore.edit { prefs ->
            prefs[IS_DYNAMIC_COLOR] = enabled
        }
    }

    suspend fun saveThemePalette(palette: String) {
        dataStore.edit { prefs ->
            prefs[THEME_PALETTE] = palette
        }
    }

    suspend fun saveFingerprint(fingerprint: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(SELECTED_FINGERPRINT, profile)] = fingerprint
        }
    }

    suspend fun saveActiveClientIds(clientIds: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(ACTIVE_CLIENT_IDS, profile)] = clientIds
        }
    }

    suspend fun saveClientIdCheckResults(resultsJson: String) {
        dataStore.edit { prefs ->
            prefs[CLIENT_ID_CHECK_RESULTS] = resultsJson
        }
    }

    suspend fun saveVkHashCheckResults(resultsJson: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(VK_HASH_CHECK_RESULTS, profile)] = resultsJson
        }
    }

    suspend fun invalidateVkHash(hash: String) {
        val normalized = hash.trim()
        if (normalized.isEmpty()) return
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            val key = getProfileKey(VK_HASH_CHECK_RESULTS, profile)
            val results = VkHashValidationCodec.decode(prefs[key] ?: "{}") +
                (normalized to VkHashValidationStatus.Invalid)
            prefs[key] = VkHashValidationCodec.encode(results)
        }
    }

    suspend fun reserveConnectionGeneration(
        proposed: Long = 0L,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): Long {
        var reserved = 0L
        dataStore.edit { prefs ->
            reserved = reserveTunnelGenerationId(
                nowSeconds.coerceAtLeast(0L),
                proposed.coerceAtLeast(0L),
                prefs[CONNECTION_GENERATION] ?: 0L,
            )
            prefs[CONNECTION_GENERATION] = reserved
        }
        return reserved
    }

    suspend fun recordConnectionGeneration(generation: Long): Long {
        var persisted = 0L
        dataStore.edit { prefs ->
            persisted = maxOf(prefs[CONNECTION_GENERATION] ?: 0L, generation.coerceAtLeast(0L))
            prefs[CONNECTION_GENERATION] = persisted
        }
        return persisted
    }

    suspend fun saveTunnelDiagnostic(code: String, message: String) {
        val normalizedCode = code.trim().take(80)
        val normalizedMessage = message.trim().replace(Regex("\\s+"), " ").take(400)
        dataStore.edit { prefs ->
            prefs[TUNNEL_LAST_DIAGNOSTIC] = "$normalizedCode|$normalizedMessage"
            prefs[TUNNEL_LAST_DIAGNOSTIC_AT] = System.currentTimeMillis()
        }
    }

    suspend fun clearTunnelDiagnostic() {
        dataStore.edit { prefs ->
            prefs.remove(TUNNEL_LAST_DIAGNOSTIC)
            prefs.remove(TUNNEL_LAST_DIAGNOSTIC_AT)
        }
    }

    suspend fun saveUpdateState(lastCheckAt: Long, latestVersion: String, error: String) {
        dataStore.edit { prefs ->
            prefs[UPDATE_LAST_CHECK_AT] = lastCheckAt
            prefs[UPDATE_LATEST_VERSION] = latestVersion
            prefs[UPDATE_LAST_ERROR] = error
        }
    }

    suspend fun saveUpdateCheckIntervalHours(hours: Int) {
        dataStore.edit { prefs ->
            prefs[UPDATE_CHECK_INTERVAL_HOURS] = hours
        }
    }

    suspend fun saveUpdatePostpone(version: String, until: Long) {
        dataStore.edit { prefs ->
            prefs[UPDATE_POSTPONE_VERSION] = version
            prefs[UPDATE_POSTPONE_UNTIL] = until
        }
    }

    suspend fun saveUpdateDialogShown(version: String, shownAt: Long) {
        dataStore.edit { prefs ->
            prefs[UPDATE_DIALOG_LAST_SHOWN_VERSION] = version
            prefs[UPDATE_DIALOG_LAST_SHOWN_AT] = shownAt
        }
    }

    suspend fun saveUpdateDialogAction(version: String, action: String, actedAt: Long) {
        dataStore.edit { prefs ->
            prefs[UPDATE_DIALOG_LAST_ACTION_VERSION] = version
            prefs[UPDATE_DIALOG_LAST_ACTION] = action
            prefs[UPDATE_DIALOG_LAST_ACTION_AT] = actedAt
        }
    }

    suspend fun saveActiveProfile(profile: Int) {
        dataStore.edit { prefs ->
            prefs[ACTIVE_PROFILE] = profile.coerceIn(
                CsqttConstants.Profiles.MIN_INDEX,
                CsqttConstants.Profiles.MAX_INDEX,
            )
        }
    }

    suspend fun saveShowSystemApps(enabled: Boolean) {
        dataStore.edit { prefs ->
            prefs[SHOW_SYSTEM_APPS] = enabled
        }
    }

    suspend fun saveOrangeTunnelEnabled(packages: String) {
        dataStore.edit { prefs ->
            prefs[ORANGE_TUNNEL_ENABLED] = packages
        }
    }

    suspend fun saveCsqttParticipantLink(link: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(CSQTT_LINK, profile)] = link
        }
    }

    suspend fun saveParticipantShowLogs(show: Boolean) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(PARTICIPANT_SHOW_LOGS, profile)] = show
        }
    }

    suspend fun saveWorkersPerHash(workersPerHash: Int) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(WORKERS_PER_HASH, profile)] = WorkerCountPolicy.normalize(workersPerHash, maximum = CsqttConstants.Tunnel.MAX_WORKERS)
        }
    }

    suspend fun saveParticipantTunnelSettings(vkHashes: String, workersPerHash: Int) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(VK_HASHES, profile)] = vkHashes
            prefs[getProfileKey(WORKERS_PER_HASH, profile)] =
                WorkerCountPolicy.normalize(workersPerHash, maximum = CsqttConstants.Tunnel.MAX_WORKERS)
        }
    }

    suspend fun saveExcludedApps(packages: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(EXCLUDED_APPS, profile)] = packages
            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

    suspend fun saveWhitelistApps(packages: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(WHITELIST_APPS, profile)] = packages
            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

    suspend fun saveAppRoutingLists(blacklist: String, whitelist: String, isWhitelist: Boolean? = null) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(EXCLUDED_APPS, profile)] = blacklist
            prefs[getProfileKey(WHITELIST_APPS, profile)] = whitelist
            if (isWhitelist != null) prefs[getProfileKey(IS_WHITELIST, profile)] = isWhitelist
            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

    suspend fun saveVkAuthMode(mode: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            val normalized = when (mode) {
                CsqttConstants.VkAuth.MODE_CAPTCHA -> CsqttConstants.VkAuth.MODE_CAPTCHA
                CsqttConstants.VkAuth.MODE_AUTO_JS -> CsqttConstants.VkAuth.MODE_AUTO_JS
                else -> CsqttConstants.VkAuth.MODE_CALLS
            }
            prefs[getProfileKey(VK_AUTH_MODE, profile)] = normalized
            prefs[getProfileKey(VK_HASH_MODE, profile)] = vkHashModeForAuthMode(
                requestedAuthMode = normalized,
                currentHashMode = prefs[getProfileKey(VK_HASH_MODE, profile)],
                hasVkToken = readSecret(prefs, VK_ACCESS_TOKEN_ENCRYPTED, VK_ACCESS_TOKEN, profile).isNotBlank(),
            )
        }
    }

    suspend fun saveObfsMode(mode: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(OBFS_MODE, profile)] = mode
        }
    }

    suspend fun saveTurnTransport(transport: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(TURN_TRANSPORT, profile)] = when (transport) {
                CsqttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS -> CsqttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS
                else -> CsqttConstants.Tunnel.DEFAULT_TURN_TRANSPORT
            }
        }
    }

    suspend fun saveSrtpMode(mode: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(SRTP_MODE, profile)] = when (mode) {
                CsqttConstants.SrtpMode.WRAP -> CsqttConstants.SrtpMode.WRAP
                CsqttConstants.SrtpMode.DTLS -> CsqttConstants.SrtpMode.DTLS
                else -> CsqttConstants.SrtpMode.DEFAULT
            }
        }
    }

    suspend fun saveSelectedTurnSubnet(subnetId: String, ipLimit: String? = null) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            val limit = ipLimit ?: prefs[getProfileKey(TURN_SUBNET_IP_LIMIT, profile)] ?: "ALL"
            val allIps = if (subnetId.isNotBlank()) TurnSubnetRegistry.getIpsForSubnet(subnetId) else emptyList()
            val limitCount = limit.toIntOrNull()
            val ips = if (allIps.isEmpty()) {
                ""
            } else if (limitCount != null && limitCount > 0) {
                allIps.take(limitCount).joinToString(",")
            } else {
                allIps.joinToString(",")
            }
            prefs[getProfileKey(SELECTED_TURN_SUBNET, profile)] = subnetId
            prefs[getProfileKey(CUSTOM_TURN_IPS, profile)] = ips
            if (ipLimit != null) {
                prefs[getProfileKey(TURN_SUBNET_IP_LIMIT, profile)] = ipLimit
            }
        }
    }

    suspend fun saveTurnSubnetIpLimit(limit: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            val subnetId = prefs[getProfileKey(SELECTED_TURN_SUBNET, profile)] ?: ""
            val allIps = if (subnetId.isNotBlank()) TurnSubnetRegistry.getIpsForSubnet(subnetId) else emptyList()
            val limitCount = limit.toIntOrNull()
            val ips = if (allIps.isEmpty()) {
                ""
            } else if (limitCount != null && limitCount > 0) {
                allIps.take(limitCount).joinToString(",")
            } else {
                allIps.joinToString(",")
            }
            prefs[getProfileKey(TURN_SUBNET_IP_LIMIT, profile)] = limit
            prefs[getProfileKey(CUSTOM_TURN_IPS, profile)] = ips
        }
    }

    suspend fun saveExtraWorkers(enabled: Boolean = false) {
        dataStore.edit { prefs ->
            for (p in CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX) {
                prefs[getProfileKey(EXTRA_WORKERS, p)] = false
            }
        }
    }

    suspend fun saveAutoJsRiskAcknowledged(acknowledged: Boolean) {
        dataStore.edit { prefs ->
            prefs[AUTO_JS_RISK_ACKNOWLEDGED] = acknowledged
        }
    }

    suspend fun saveTcpTransportRiskAcknowledged(acknowledged: Boolean) {
        dataStore.edit { prefs ->
            prefs[TCP_TRANSPORT_RISK_ACKNOWLEDGED] = acknowledged
        }
    }

    suspend fun saveAutoPauseOnWifi(enabled: Boolean) {
        dataStore.edit { prefs ->
            prefs[AUTO_PAUSE_ON_WIFI] = enabled
        }
    }

    suspend fun markBatteryOptimizationPromptHandled() {
        dataStore.edit { prefs ->
            prefs[BATTERY_OPTIMIZATION_PROMPT_HANDLED] = true
        }
    }

    suspend fun saveCaptchaMode(mode: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(CAPTCHA_MODE, profile)] = mode
        }
    }

    suspend fun saveCaptchaSolveMethod(method: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(CAPTCHA_SOLVE_METHOD, profile)] = method
        }
    }

    suspend fun saveWbvCaptchaSolveMethod(method: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(CAPTCHA_WBV_SOLVE_METHOD, profile)] = method
            if (prefs[getProfileKey(CAPTCHA_MODE, profile)] == "wv") {
                prefs[getProfileKey(CAPTCHA_SOLVE_METHOD, profile)] = method
            }
        }
    }

    suspend fun saveVkHashMode(mode: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            val currentAuthMode = prefs[getProfileKey(VK_AUTH_MODE, profile)]
            val nextAuthMode = vkAuthModeForHashMode(mode, currentAuthMode)
            val selection = normalizeVkModeSelection(
                requestedAuthMode = nextAuthMode,
                requestedHashMode = mode,
                hasVkToken = readSecret(prefs, VK_ACCESS_TOKEN_ENCRYPTED, VK_ACCESS_TOKEN, profile).isNotBlank(),
            )
            prefs[getProfileKey(VK_AUTH_MODE, profile)] = selection.authMode
            prefs[getProfileKey(VK_HASH_MODE, profile)] = selection.hashMode
        }
    }

    suspend fun saveVkAccessToken(token: String, userId: String) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs.putSecret(VK_ACCESS_TOKEN_ENCRYPTED, VK_ACCESS_TOKEN, token, profile)
            prefs[getProfileKey(VK_ACCESS_TOKEN_USER_ID, profile)] = userId
        }
    }

    suspend fun clearVkAccessToken() {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs.remove(getProfileKey(VK_ACCESS_TOKEN_ENCRYPTED, profile))
            prefs.remove(getProfileKey(VK_ACCESS_TOKEN, profile))
            prefs.remove(getProfileKey(VK_ACCESS_TOKEN_USER_ID, profile))
        }
    }

    suspend fun saveIsWhitelist(enabled: Boolean) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            prefs[getProfileKey(IS_WHITELIST, profile)] = enabled
            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

    suspend fun saveExceptionsMode(packages: String, isWhitelist: Boolean) {
        dataStore.edit { prefs ->
            val profile = prefs[ACTIVE_PROFILE] ?: 0
            if (isWhitelist) {
                prefs[getProfileKey(WHITELIST_APPS, profile)] = packages
            } else {
                prefs[getProfileKey(EXCLUDED_APPS, profile)] = packages
            }
            prefs[getProfileKey(IS_WHITELIST, profile)] = isWhitelist
            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

    /**
     * Легаси хранил единственный список в `EXCLUDED_APPS` и в белом режиме
     * держал там белый список. Переносим его в `WHITELIST_APPS`, а чёрную
     * ветку оставляем пустой: синтез «всё установленное минус белый список»
     * под чёрным правилом прочитался бы как настоящий чёрный список и увёл бы
     * мимо тоннеля почти всё устройство. Профиль, у которого белый ключ уже
     * заполнен, не трогаем — это состояние новой настройки, а не легаси.
     */
    suspend fun migrateLegacyWhitelistMode() {
        val currentPrefs = dataStore.data.first()
        if (currentPrefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] == true) return

        dataStore.edit { prefs ->
            if (prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] == true) return@edit

            for (profile in CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX) {
                val whitelistKey = getProfileKey(IS_WHITELIST, profile)
                val appsKey = getProfileKey(EXCLUDED_APPS, profile)
                val whitelistAppsKey = getProfileKey(WHITELIST_APPS, profile)
                if (prefs[whitelistKey] == true && prefs[whitelistAppsKey] == null) {
                    val migrated = LegacyAppListsMigration.fromLegacyWhiteList(prefs[appsKey])
                    prefs[appsKey] = migrated.black
                    prefs[whitelistAppsKey] = migrated.white
                }
            }

            prefs[SPLIT_TUNNEL_WHITELIST_MIGRATED] = true
        }
    }

        /**
     * Одноразовый ремонт чёрной ветки, которую прежняя легаси-миграция успела
     * синтезировать в белом профиле.
     *
     * Миграция 2.5.0/2.5.1 для белого профиля с непустым `EXCLUDED_APPS` писала
     * туда «все установленные минус старый белый список» и всегда ставила
     * `SPLIT_TUNNEL_WHITELIST_MIGRATED = true`. Новая [migrateLegacyWhitelistMode]
     * выходит по этому флагу на первой строке, поэтому до данных обновившихся
     * пользователей она не доходит. Под чёрным правилом сервера `effectivePackages`
     * читает именно эту ветку и уводит мимо тоннеля почти всё устройство.
     *
     * Поэтому ремонт идёт отдельным ключом и отдельным проходом: у каждого профиля
     * в белом режиме чёрная ветка очищается. У белого профиля непустой чёрный
     * список почти всегда синтезирован прежней миграцией; осознанно сохранённый
     * пользователем список (переключился в чёрный режим, отредактировал, вернулся
     * в белый) эта миграция тоже затирает — осознанный размен, иначе перевёрнутый
     * синтез остаётся у всех обновившихся. Профили в чёрном режиме не трогаем: там
     * чёрный список пользовательский.
     *
     * Повторный запуск ничего не меняет: проход закрыт собственным ключом, а не
     * `SPLIT_TUNNEL_WHITELIST_MIGRATED` (его выставляет любое сохранение списков).
     */
    suspend fun repairInvertedLocalBlacklist() {
        val currentPrefs = dataStore.data.first()
        if (currentPrefs[SPLIT_TUNNEL_INVERTED_LIST_REPAIRED] == true) return

        dataStore.edit { prefs ->
            if (prefs[SPLIT_TUNNEL_INVERTED_LIST_REPAIRED] == true) return@edit

            for (profile in CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX) {
                val whitelistKey = getProfileKey(IS_WHITELIST, profile)
                val appsKey = getProfileKey(EXCLUDED_APPS, profile)
                val repaired = LegacyAppListsMigration.repairedBlacklist(
                    isWhitelist = prefs[whitelistKey] == true,
                    black = prefs[appsKey],
                )
                if (repaired != null) prefs[appsKey] = repaired
            }

            prefs[SPLIT_TUNNEL_INVERTED_LIST_REPAIRED] = true
        }
    }

    private fun readSecret(
        prefs: Preferences,
        encryptedKey: Preferences.Key<String>,
        legacyKey: Preferences.Key<String>,
        profile: Int
    ): String = readSecretState(prefs, encryptedKey, legacyKey, profile).value

    private fun readSecretState(
        prefs: Preferences,
        encryptedKey: Preferences.Key<String>,
        legacyKey: Preferences.Key<String>,
        profile: Int
    ): StoredSecret {
        val profEncryptedKey = getProfileKey(encryptedKey, profile)
        val profLegacyKey = getProfileKey(legacyKey, profile)
        return resolveStoredSecret(
            prefs[profEncryptedKey],
            prefs[profLegacyKey],
            secureStore::decrypt,
        )
    }

    private fun MutablePreferences.putSecret(
        encryptedKey: Preferences.Key<String>,
        legacyKey: Preferences.Key<String>,
        value: String,
        profile: Int
    ) {
        val profEncryptedKey = getProfileKey(encryptedKey, profile)
        val profLegacyKey = getProfileKey(legacyKey, profile)
        if (value.isBlank()) {
            remove(profEncryptedKey)
            remove(profLegacyKey)
        } else {
            this[profEncryptedKey] = secureStore.encrypt(value)
            remove(profLegacyKey)
        }
    }
}
