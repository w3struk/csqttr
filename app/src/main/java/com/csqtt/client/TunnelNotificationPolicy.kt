package com.csqtt.client

/**
 * Счётчики трафика в уведомлении туннеля перерисовываются только при включённом
 * экране: с выключенным экраном это публикация уведомления каждые несколько
 * секунд впустую. Следующий такт после включения экрана приводит текст в
 * актуальное состояние.
 */
internal object TunnelNotificationPolicy {
    fun shouldRefreshTraffic(screenInteractive: Boolean): Boolean = screenInteractive
}
