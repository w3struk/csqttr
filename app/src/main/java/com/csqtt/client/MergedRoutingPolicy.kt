package com.csqtt.client

/**
 * Слияние серверного правила и локального списка приложений.
 *
 * Режим задаёт оператор, а единственный пользовательский слой под правилом —
 * чёрный список: под чёрным правилом он дополняет запрет, под белым —
 * вычитается из разрешённого набора. Локальный белый список под правилом не
 * читается; он остаётся для локального режима, когда правила нет.
 *
 * Пустой результат легален и означает «никто через тоннель»: пустой белый
 * набор — это «никто», а не «все». Отказ поднимать VPN формирует сборщик плана
 * ([VpnAppRouting.build]); политика слияния о форме плана ничего не знает.
 */
internal object MergedRoutingPolicy {
    fun effectivePackages(
        ruleIsWhite: Boolean,
        rulePackages: Set<String>,
        localBlack: Set<String>,
    ): Set<String> = if (ruleIsWhite) {
        rulePackages - localBlack
    } else {
        rulePackages + localBlack
    }

    /**
     * Итог для карточки «Маршрутизация приложений»: сколько установленных
     * приложений идёт через тоннель, сколько мимо и кто их туда принёс —
     * правило сервера вместе с пресетом или локальный чёрный список.
     *
     * Считаются только установленные приложения, транспортные пакеты и сам
     * CSQTT исключаются всегда. [installedPackages] — сырой набор имён из
     * `PackageManager`, включая транспорт и сам CSQTT: тот же ответ, который
     * получают `VpnAppRouting.build` и per-UID триггер. Список диалога для
     * счётчиков не годится — он отфильтрован для показа, и правило из одного
     * транспорта исказило бы и предикат подмены, и числа. Пакет, попавший и в
     * правило, и в локальный список, считается один раз и относится к правилу;
     * пакет пресета из локального списка «вашим» не становится.
     *
     * Белый режим вычитает локальный чёрный список. Пакет, исключённый
     * пользователем, относится к «вашим»; возвращённый оранжевый сильнее
     * списка. «На все приложения» бывает только подменой невидимого непустого
     * СЫРОГО правила: предикат считается до вычитания, иначе исключение
     * последнего видимого пакета включало бы device-wide план и расширяло
     * покрытие. В подменённом плане исключения пользователя продолжают
     * действовать.
     */
    fun cardCounts(
        ruleIsWhite: Boolean,
        rulePackages: Set<String>,
        localBlack: Set<String>,
        preset: PresetApps,
        userEnabled: Set<String>,
        installedPackages: Set<String>,
        transportPackages: Set<String>,
    ): MergedCardCounts {
        val orange = AppRoutingPolicy.orangeTunnelEnabled(preset, userEnabled)
        val counted = installedPackages - transportPackages
        val alwaysExcluded = (preset.red intersect counted).size
        val optOut = (preset.orange intersect counted).size
        val effective = effectivePackages(ruleIsWhite, rulePackages, localBlack)

        // Подмена: непустой невидимый белый набор правила. Предикат оценивается
        // по сырому правилу, до вычитания чёрного списка, и до возвращённых
        // оранжевых. Формулы — прежние device-wide: всё, кроме пресета и не
        // возвращённых оранжевых, минус исключения пользователя.
        if (ruleIsWhite &&
            AppRoutingPolicy.isServerWhitelistInvisible(ruleIsWhite, rulePackages) {
                it in installedPackages
            }
        ) {
            val userExcluded = localBlack - orange
            val inTunnelSet = counted - preset.red - (preset.orange - orange) - userExcluded
            return MergedCardCounts(
                inTunnel = inTunnelSet.size,
                excluded = counted.size - inTunnelSet.size,
                serverAttributed = inTunnelSet.size,
                localAttributed = (userExcluded - preset.all).count { it in counted },
                alwaysExcluded = alwaysExcluded,
                optOut = optOut,
            )
        }

        if (ruleIsWhite) {
            // «В тоннель»: правило минус чёрный список, минус весь пресет,
            // плюс возвращённые пользователем оранжевые.
            val inTunnelSet = (effective - preset.all) + orange
            val inTunnel = (inTunnelSet intersect counted).size
            return MergedCardCounts(
                inTunnel = inTunnel,
                excluded = counted.size - inTunnel,
                serverAttributed = inTunnelSet.count { it in counted },
                localAttributed = ((localBlack intersect rulePackages) - preset.all - orange)
                    .count { it in counted },
                alwaysExcluded = alwaysExcluded,
                optOut = optOut,
            )
        }

        // «Мимо тоннеля»: правило, локальный чёрный список и весь пресет,
        // минус оранжевые, которые пользователь вернул в тоннель.
        val excludedSet = (rulePackages + localBlack + preset.all) - orange
        val excluded = (excludedSet intersect counted).size
        val serverAttributed = ((rulePackages + preset.all) - orange).count { it in counted }
        return MergedCardCounts(
            inTunnel = counted.size - excluded,
            excluded = excluded,
            serverAttributed = serverAttributed,
            // Всё, что исключено не правилом и не пресетом, принёс локальный
            // список; формула совпадает с |(localBlack \ (rule ∪ preset)) ∩ counted|.
            localAttributed = excluded - serverAttributed,
            alwaysExcluded = alwaysExcluded,
            optOut = optOut,
        )
    }
}

/**
 * Счётчики карточки «Маршрутизация приложений» под серверным правилом:
 * общий итог и разбивка «от правила сервера / ваши».
 */
internal data class MergedCardCounts(
    val inTunnel: Int,
    val excluded: Int,
    val serverAttributed: Int,
    val localAttributed: Int,
    val alwaysExcluded: Int,
    val optOut: Int,
)
