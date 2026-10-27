package com.csqtt.client

/**
 * Нужно ли пересобирать VPN после установки, удаления или обновления пакета.
 *
 * Android задаёт per-app маршрутизацию диапазонами UID в ядре, а не списком
 * пакетов, и для VPN, созданных через `VpnService.Builder.establish()`, при
 * установке пакета их не пересчитывает. Поэтому новый UID попадает в тоннель
 * по арифметике диапазона (в режиме «исключить») либо остаётся мимо него
 * (в режиме «включить»), а переустановка исключённого пакета оставляет в
 * «дырке» старый UID и пускает в тоннель новый.
 *
 * Пересборка не бесплатна: `ConnectivityService.maybeCloseSockets` рвёт TCP у
 * UID, у которых изменилось покрытие. Поэтому триггер срабатывает только на
 * пакеты, которые действительно задают план маршрутизации:
 * - пакеты списка серверного правила;
 * - оранжевые, которых пользователь вернул в туннель ([orangeEnabled]):
 *   в белом списке они входят в allow-набор, в остальных режимах вычитаются из
 *   disallow-набора, то есть участвуют в плане всегда;
 * - транспортные пакеты и остальной пресет — но только когда план несёт явный
 *   набор исключений ([planExcludesPackages]): в обычном белом списке и
 *   транспорт, и пресет вычтены из allow-набора, поэтому новый UID и без
 *   пересборки остаётся мимо тоннеля.
 */
internal object PackageChangePolicy {
    /** Обновление приложения присылает несколько broadcast'ов подряд. */
    const val REBUILD_DEBOUNCE_MS = 1_500L

    /**
     * @param transportPackages пакеты, которые план держит мимо тоннеля
     *   (`TunVpnService` передаёт `CsqttConstants.General.VK_TRANSPORT_PACKAGES`
     *   и сам CSQTT). Влияют на покрытие только при [planExcludesPackages].
     * @param orangeEnabled оранжевые пресета, возвращённые пользователем в
     *   туннель (снимок `SettingsStore.cachedOrangeTunnelEnabled`).
     * @param planExcludesPackages несёт ли план явный набор исключений
     *   (`Disallow`): чёрный список и ветка «на все приложения». Только тогда
     *   транспорт и остальной пресет меняют покрытие; в обычном белом списке
     *   они вычтены из allow-набора и остаются мимо тоннеля без пересборки.
     */
    fun needsVpnRebuild(
        packageName: String,
        preset: PresetApps,
        rulePackages: Set<String>,
        transportPackages: Set<String>,
        orangeEnabled: Set<String>,
        planExcludesPackages: Boolean,
    ): Boolean = packageName.isNotEmpty() &&
        (packageName in rulePackages ||
            packageName in orangeEnabled ||
            (planExcludesPackages &&
                (packageName in transportPackages || packageName in preset.all)))

    /**
     * Отображение серверного правила в аргументы [needsVpnRebuild].
     *
     * Единственное место, где сервис выводит форму плана из правила. Вынесено
     * из `TunnelService`, чтобы инверсию `isWhite` или зашитый признак формы
     * ловили юнит-тесты. Сама ветка «правило на все приложения» не
     * переписывается здесь: её решает [AppRoutingPolicy.isDeviceWideRule],
     * общая с карточкой маршрутизации и сборщиком плана.
     */
    fun needsVpnRebuild(
        rule: ServerRoutingRule,
        packageName: String,
        transportPackages: Set<String>,
        orangeEnabled: Set<String>,
    ): Boolean {
        val rulePackages = rule.packages.toSet()
        val planExcludesPackages = !rule.isWhite ||
            AppRoutingPolicy.isDeviceWideRule(rule.isWhite, rulePackages)
        return needsVpnRebuild(
            packageName = packageName,
            preset = PresetApps(
                red = rule.presetRed.toSet(),
                orange = rule.presetOrange.toSet(),
            ),
            rulePackages = rulePackages,
            transportPackages = transportPackages,
            orangeEnabled = orangeEnabled,
            planExcludesPackages = planExcludesPackages,
        )
    }
}
