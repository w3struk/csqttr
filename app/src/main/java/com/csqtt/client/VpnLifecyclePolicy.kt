package com.csqtt.client

/**
 * Решения о жизни VPN-интерфейса, отделённые от Android-службы.
 *
 * Инвариант: интерфейс не должен существовать, когда туннеля нет. Пока интерфейс поднят
 * с маршрутом 0.0.0.0/0, весь трафик устройства уходит в мёртвый tun — «чёрная дыра»
 * с горящим значком VPN и без интернета.
 */
internal object VpnLifecyclePolicy {
    /**
     * Нужно ли закрыть интерфейс после завершения дочернего Rust-процесса.
     * При запланированном перезапуске интерфейс переиспользуется новым процессом.
     */
    fun shouldCloseVpnOnProcessExit(restartScheduled: Boolean, tunnelRunning: Boolean): Boolean =
        !restartScheduled && !tunnelRunning

    /** Стоит ли делать ещё одну попытку передать TUN fd. */
    fun shouldRetryFdDelivery(tunnelRunning: Boolean, attempt: Int, maxAttempts: Int): Boolean =
        tunnelRunning && attempt in 1..maxAttempts

    /** Можно ли поднимать (или пересобирать) интерфейс: только при живом туннеле. */
    fun shouldReestablishVpn(tunnelRunning: Boolean): Boolean = tunnelRunning

    /**
     * Нужно ли сбрасывать сохранённое состояние «туннель был запущен» и TUNCONF.
     *
     * Автопауза на Wi-Fi — это пауза, а не остановка: её намерение возобновить туннель
     * сохраняется ДО паузы, поэтому сбрасывать его нельзя — иначе автопауза перестанет
     * возобновляться, а перезапуск службы (START_STICKY) увидит «туннель не запускался».
     */
    fun shouldClearPersistedRunState(preserveWifiAutoPause: Boolean): Boolean =
        !preserveWifiAutoPause
}
