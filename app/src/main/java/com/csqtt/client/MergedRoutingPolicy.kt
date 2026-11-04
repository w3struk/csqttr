package com.csqtt.client

/**
 * Объединение серверного правила и локального списка приложений.
 *
 * Режим задаёт оператор, а не профиль: правило чёрное — читается локальный
 * чёрный список, правило белое — локальный белый. Список противоположного
 * режима не читается вовсе, иначе список читался бы «наоборот».
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
        localWhite: Set<String>,
    ): Set<String> = if (ruleIsWhite) {
        rulePackages + localWhite
    } else {
        rulePackages + localBlack
    }

    /**
     * Итог для карточки «Маршрутизация приложений»: сколько установленных
     * приложений идёт через тоннель, сколько мимо и кто их туда принёс —
     * правило сервера вместе с пресетом или локальный список.
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
     * Белый режим считается обычными формулами и при пустом эффективном
     * наборе даёт «0 в туннеле» — ветки «правило на все приложения» здесь нет.
     * «На все приложения» бывает только подменой невидимого непустого белого
     * набора: тогда счётчики считаются device-wide формулами (локальный список
     * в план не входит, поэтому `localAttributed = 0`).
     */
    fun cardCounts(
        ruleIsWhite: Boolean,
        rulePackages: Set<String>,
        localBlack: Set<String>,
        localWhite: Set<String>,
        preset: PresetApps,
        userEnabled: Set<String>,
        installedPackages: Set<String>,
        transportPackages: Set<String>,
    ): MergedCardCounts {
        val orange = AppRoutingPolicy.orangeTunnelEnabled(preset, userEnabled)
        val counted = installedPackages - transportPackages
        val alwaysExcluded = (preset.red intersect counted).size
        val optOut = (preset.orange intersect counted).size
        val effective = effectivePackages(ruleIsWhite, rulePackages, localBlack, localWhite)

        // Подмена (спека §2, §7.8): непустой белый набор, в котором не видно ни
        // одного установленного пакета. Предикат общий с VpnAppRouting.build и
        // per-UID триггером; оценивается по эффективному набору до возвращённых
        // оранжевых. Формулы — прежние device-wide: всё, кроме пресета и
        // не возвращённых оранжевых.
        if (ruleIsWhite &&
            AppRoutingPolicy.isServerWhitelistInvisible(ruleIsWhite, effective) {
                it in installedPackages
            }
        ) {
            val inTunnelSet = counted - preset.red - (preset.orange - orange)
            return MergedCardCounts(
                inTunnel = inTunnelSet.size,
                excluded = counted.size - inTunnelSet.size,
                serverAttributed = inTunnelSet.size,
                localAttributed = 0,
                alwaysExcluded = alwaysExcluded,
                optOut = optOut,
            )
        }

        if (ruleIsWhite) {
            // «В тоннель»: объединённый набор минус весь пресет, плюс
            // возвращённые пользователем оранжевые.
            val inTunnelSet = (effective - preset.all) + orange
            val inTunnel = (inTunnelSet intersect counted).size
            val serverAttributed = ((rulePackages - preset.all) + orange).count { it in counted }
            val localAttributed = (localWhite - rulePackages - preset.all).count { it in counted }
            return MergedCardCounts(
                inTunnel = inTunnel,
                excluded = counted.size - inTunnel,
                serverAttributed = serverAttributed,
                localAttributed = localAttributed,
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
