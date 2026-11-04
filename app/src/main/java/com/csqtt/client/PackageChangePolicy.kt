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
 * - пакеты локального списка приложений ([localPackages]): в чёрном режиме они
 *   входят в disallow-набор, в белом — в allow-набор, то есть задают план в
 *   любой его форме;
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
     * @param localPackages пакеты локального списка приложений профиля (тот
     *   список, который соответствует режиму плана). Локальные пакеты задают
     *   план в обеих формах, поэтому пересборка нужна независимо от
     *   [planExcludesPackages].
     * @param transportPackages пакеты, которые план держит мимо тоннеля
     *   (`TunVpnService` передаёт `CsqttConstants.General.VK_TRANSPORT_PACKAGES`
     *   и сам CSQTT). Влияют на покрытие только при [planExcludesPackages].
     * @param orangeEnabled оранжевые пресета, возвращённые пользователем в
     *   туннель (снимок `SettingsStore.cachedOrangeTunnelEnabled`).
     * @param planExcludesPackages несёт ли план явный набор исключений
     *   (`Disallow`): чёрный список. Только тогда транспорт и остальной пресет
     *   меняют покрытие; в обычном белом списке они вычтены из allow-набора и
     *   остаются мимо тоннеля без пересборки.
     */
    fun needsVpnRebuild(
        packageName: String,
        preset: PresetApps,
        rulePackages: Set<String>,
        transportPackages: Set<String>,
        orangeEnabled: Set<String>,
        planExcludesPackages: Boolean,
        localPackages: Set<String> = emptySet(),
    ): Boolean = packageName.isNotEmpty() &&
        (packageName in rulePackages ||
            packageName in localPackages ||
            packageName in orangeEnabled ||
            (planExcludesPackages &&
                (packageName in transportPackages || packageName in preset.all)))

    /**
     * Отображение серверного правила в аргументы [needsVpnRebuild].
     *
     * Единственное место, где сервис выводит форму плана из правила. Вынесено
     * из `TunnelService`, чтобы инверсию `isWhite` или зашитый признак формы
     * ловили юнит-тесты. Пустое белое правило теперь план-`Failure` (VPN не
     * поднят, триггер недостижим), поэтому политика тотальна и трактует его как
     * обычный allow-план. Подменённое правило даёт фактический план device-wide
     * `Disallow`, поэтому транспорт и остальной пресет меняют покрытие и
     * пересборка обязательна — как в прежней device-wide ветке.
     *
     * @param localPackages пакеты локального списка, соответствующего режиму
     *   правила: под чёрным правилом — локальный чёрный, под белым — локальный
     *   белый. Под правилом они дополняют план и пересборку триггерят так же,
     *   как пакеты правила — кроме подменённого плана: там они не входят в план
     *   (в 7-аргументную форму уходят пустыми), но их удаление ловится
     *   отдельным дизъюнктом — это переход «в подмену».
     * @param planSubstituted фактический план — device-wide `Disallow` из-за
     *   подмены невидимого белого списка. Пресет и транспорт тогда задают
     *   покрытие, а локальный пакет, которого не видно установленным, может
     *   только исчезнуть — и это тоже меняет план.
     */
    fun needsVpnRebuild(
        rule: ServerRoutingRule,
        packageName: String,
        transportPackages: Set<String>,
        orangeEnabled: Set<String>,
        localPackages: Set<String> = emptySet(),
        planSubstituted: Boolean = false,
    ): Boolean {
        val rulePackages = rule.packages.toSet()
        // Под подменой локальные пакеты не считаются элементами плана: план
        // device-wide. Дизъюнкт смотрит на входящий список до обнуления.
        val localPackageDisappeared = planSubstituted && packageName in localPackages
        val planExcludesPackages = !rule.isWhite || planSubstituted
        return localPackageDisappeared || needsVpnRebuild(
            packageName = packageName,
            preset = PresetApps(
                red = rule.presetRed.toSet(),
                orange = rule.presetOrange.toSet(),
            ),
            rulePackages = rulePackages,
            transportPackages = transportPackages,
            orangeEnabled = orangeEnabled,
            planExcludesPackages = planExcludesPackages,
            localPackages = if (planSubstituted) emptySet() else localPackages,
        )
    }

    /**
     * Локальный режим, когда серверного правила нет: главный список профиля и
     * его режим ([isWhitelist]). Пресета и оранжевых здесь нет, поэтому форма
     * плана — просто `!isWhitelist`: чёрный список несёт явный disallow-набор,
     * белый — allow-набор.
     */
    fun needsVpnRebuild(
        isWhitelist: Boolean,
        localPackages: Set<String>,
        packageName: String,
        transportPackages: Set<String>,
    ): Boolean = needsVpnRebuild(
        packageName = packageName,
        preset = PresetApps(red = emptySet(), orange = emptySet()),
        rulePackages = emptySet(),
        transportPackages = transportPackages,
        orangeEnabled = emptySet(),
        planExcludesPackages = !isWhitelist,
        localPackages = localPackages,
    )
}
