package com.csqtt.client

/**
 * IP-роутинг включается тогда и только тогда, когда список IP непуст.
 *
 * Отдельного выключателя в UI нет: сохранение списка IP ставит `ipRoutingEnabled`,
 * но ничего его не снимает, а у конфигов, созданных до этого флага, его нет
 * вовсе. Поэтому список и есть намерение — и он же решает, включать ли
 * роутинг. То же правило и в командной строке клиента, и во всех сборщиках
 * `TunnelParams`.
 */
internal object IpRoutingPolicy {
    fun isEnabled(ipList: String): Boolean = ipList.isNotBlank()

    /**
     * Правило сервера меняет маршруты VPN: `excludeRoutes` собираются из
     * `ips`/`ipIsWhite`, поэтому смена списка IP или режима сама по себе требует
     * пересборки — иначе маршруты остаются прежними до переподключения.
     *
     * В режиме белого списка (`ipIsWhite`) IP маршрутов не создают, поэтому
     * смена именно этого списка пересборки не требует.
     */
    fun needsVpnRebuild(previous: ServerRoutingRule?, next: ServerRoutingRule): Boolean =
        previous == null ||
            previous.isWhite != next.isWhite ||
            previous.packages.toSet() != next.packages.toSet() ||
            previous.ipIsWhite != next.ipIsWhite ||
            (!next.ipIsWhite && previous.ips.toSet() != next.ips.toSet())
}
