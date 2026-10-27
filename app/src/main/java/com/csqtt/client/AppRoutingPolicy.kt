package com.csqtt.client

/** Уровень риска приложения из пресета российских приложений. */
internal enum class PresetRisk { RED, ORANGE }

/**
 * Пресет сервера: `red` детектит VPN и блокирует аккаунт, `orange` без туннеля
 * может не открыться и потому идёт мимо него по умолчанию.
 */
internal data class PresetApps(
    val red: Set<String>,
    val orange: Set<String>,
) {
    val all: Set<String> get() = red + orange

    fun riskOf(packageName: String): PresetRisk? = when (packageName) {
        in red -> PresetRisk.RED
        in orange -> PresetRisk.ORANGE
        else -> null
    }
}

/**
 * Итог серверного правила для карточки приложений: сколько установленных
 * приложений реально идёт через туннель, сколько мимо него, а также сколько
 * красных («всегда мимо туннеля») и оранжевых («можно отключить») стоит на
 * устройстве.
 */
internal data class RoutingCardCounts(
    val inTunnel: Int,
    val excluded: Int,
    val alwaysExcluded: Int,
    val optOut: Int,
)

/**
 * Матрица режим × уровень: какие пакеты фактически попадают в туннель.
 *
 * Красный уровень сильнее любого выбора оператора — в белом списке он вычитается
 * из пакетов правила. Оранжевый по умолчанию вне туннеля, поэтому из пакетов
 * правила он тоже вычитается: в белом режиме его возвращает только
 * пользовательский список `U` — `(P \ R \ O) ∪ (O ∩ U)`. В чёрном режиме вычитание
 * `U` делает вызывающий (`TunVpnService`), потому что там оно идёт по другую
 * сторону формулы.
 */
internal object AppRoutingPolicy {
    fun forcedExcluded(preset: PresetApps): Set<String> = preset.red

    fun allowedInTunnel(rulePackages: Set<String>, preset: PresetApps): Set<String> =
        rulePackages - preset.red - preset.orange

    fun excludedInTunnel(rulePackages: Set<String>, preset: PresetApps): Set<String> =
        rulePackages + preset.red + preset.orange

    fun orangeTunnelEnabled(preset: PresetApps, userEnabled: Set<String>): Set<String> =
        (preset.orange - preset.red) intersect userEnabled

    fun toggleOrange(userEnabled: Set<String>, packageName: String): Set<String> =
        if (packageName in userEnabled) userEnabled - packageName else userEnabled + packageName

    /**
     * «Правило на все приложения»: белый список оператора без единого пакета.
     * Такое правило раздаёт домены и адреса всему устройству — в туннель идёт всё
     * установленное, кроме пресета. Решение общее для карточки и для
     * `TunVpnService`, чтобы они не разошлись.
     */
    fun isDeviceWideRule(isWhite: Boolean, rulePackages: Set<String>): Boolean =
        isWhite && rulePackages.isEmpty()

    /**
     * Счётчики для карточки «Маршрутизация приложений»: что серверное правило
     * делает на этом устройстве.
     *
     * Белый режим бывает двух видов. Пустой список пакетов оператора — это
     * «правило на все приложения» ([isDeviceWideRule]): в туннель идёт всё
     * установленное, кроме красных и не возвращённых пользователем оранжевых.
     * Непустой список — обычный белый список. Без серверного правила считать
     * нечего, поэтому результат `null`: карточка в этом случае показывает
     * локальные списки.
     */
    fun serverRuleCounts(
        hasServerRule: Boolean,
        isWhite: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
        userEnabled: Set<String>,
        installedPackages: Set<String>,
    ): RoutingCardCounts? {
        if (!hasServerRule) return null
        val userOranges = orangeTunnelEnabled(preset, userEnabled)
        val excluded = if (isWhite) {
            val inTunnel = if (isDeviceWideRule(isWhite, rulePackages)) {
                installedPackages - preset.red - (preset.orange - userOranges)
            } else {
                (allowedInTunnel(rulePackages, preset) + userOranges) intersect installedPackages
            }
            installedPackages - inTunnel
        } else {
            (excludedInTunnel(rulePackages, preset) - userOranges) intersect installedPackages
        }
        return RoutingCardCounts(
            inTunnel = (installedPackages - excluded).size,
            excluded = excluded.size,
            alwaysExcluded = (preset.red intersect installedPackages).size,
            optOut = (preset.orange intersect installedPackages).size,
        )
    }
}

/**
 * Что `TunVpnService` передаёт в `VpnService.Builder`. `Builder` допускает либо
 * allow-, либо disallow-список, но не оба сразу, поэтому решение — ровно один
 * вариант.
 */
internal sealed interface VpnAppsPlan {
    /** Белый режим: в туннель идут только эти пакеты. */
    data class Allow(val packages: List<String>) : VpnAppsPlan

    /**
     * Мимо туннеля идут эти пакеты. CSQTT исключает себя отдельно и первым,
     * потому что ошибка именно на этом шаге фатальна для VPN; [deviceWide]
     * отличает «правило на все приложения» от обычного чёрного списка.
     */
    data class Disallow(
        val packages: List<String>,
        val deviceWide: Boolean = false,
    ) : VpnAppsPlan

    /** VPN поднимать нельзя: [message] называет настоящую причину отказа. */
    data class Failure(val message: String) : VpnAppsPlan
}

/**
 * Выбор наборов приложений для `VpnService.Builder` — самое опасное решение
 * сервиса: ошибка здесь пускает красное приложение в туннель или оставляет
 * пользователя без VPN. Поэтому оно живёт вне Android и проверяется на JVM:
 * `isPackageInstalled` и `transportPackages` приходят входами.
 *
 * Поведение повторяет то, что раньше было инлайном в `TunVpnService.startVpn`.
 */
internal object VpnAppRouting {
    fun build(
        hasServerRule: Boolean,
        isWhite: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
        userEnabled: Set<String>,
        transportPackages: Set<String>,
        selfPackage: String,
        isInstalled: (String) -> Boolean,
    ): VpnAppsPlan {
        val orangeEnabled = AppRoutingPolicy.orangeTunnelEnabled(preset, userEnabled)

        if (!isWhite) {
            // Операторские пакеты плюс весь пресет, минус оранжевые, которым
            // пользователь разрешил идти в туннель. CSQTT и транспортные пакеты
            // исключаются всегда; себя сервис добавляет отдельным вызовом.
            val excluded = if (hasServerRule) {
                AppRoutingPolicy.excludedInTunnel(rulePackages, preset) - orangeEnabled
            } else {
                rulePackages
            }
            // Набор, а не список: пакет, который есть и в правиле оператора, и в
            // транспорте, должен попасть в disallow-список один раз, чтобы сервис
            // не звал `addDisallowedApplication` дважды. Порядок обхода — правило,
            // затем транспорт.
            val packageSet = LinkedHashSet(excluded)
            packageSet += transportPackages
            packageSet -= selfPackage
            return VpnAppsPlan.Disallow(
                packages = packageSet.filter(isInstalled),
            )
        }

        val allowedSet = AppRoutingPolicy.allowedInTunnel(rulePackages, preset) + orangeEnabled
        val installedIncluded = allowedSet
            .filter { pkg -> pkg !in transportPackages && isInstalled(pkg) }
            .toSet()
        // Ветку «правило на все приложения» выбирает список оператора, а не
        // эффективный набор: иначе непустой U сделал бы набор непустым и сузил бы VPN
        // до одного разрешённого оранжевого приложения вместо «все приложения, кроме
        // пресета». Признак общий с карточкой — [AppRoutingPolicy.isDeviceWideRule].
        val deviceWide = hasServerRule && AppRoutingPolicy.isDeviceWideRule(isWhite, rulePackages)
        if (installedIncluded.isNotEmpty() && !deviceWide) {
            return VpnAppsPlan.Allow(installedIncluded.toList())
        }

        // An empty server package list means a device-wide domain/IP rule.
        // A nonempty list with no installed matches must never broaden to all apps.
        if (!deviceWide) {
            return VpnAppsPlan.Failure(
                emptyWhitelistMessage(
                    hasServerRule = hasServerRule,
                    rulePackages = rulePackages,
                    preset = preset,
                    orangeEnabled = orangeEnabled,
                    transportPackages = transportPackages,
                    isInstalled = isInstalled,
                )
            )
        }

        // Пресет идёт мимо туннеля вместе со всеми остальными. Оранжевые из U не
        // исключаются — пользователь вернул их в туннель.
        val disallowed = (transportPackages - selfPackage) +
            (AppRoutingPolicy.forcedExcluded(preset) + (preset.orange - orangeEnabled))
                .filter { it !in transportPackages }
        return VpnAppsPlan.Disallow(
            packages = disallowed.filter { it != selfPackage && isInstalled(it) },
            deviceWide = true,
        )
    }

    /**
     * Какой стороной чинится причина отказа. Правило сервера правит оператор, а
     * возврат оранжевых — только пользователь в приложении, поэтому общий совет
     * «поправьте правило на сервере» уводил бы его не туда.
     */
    private enum class Fix(val advice: String) {
        SERVER("Поправьте правило на сервере"),
        USER("Верните оранжевые приложения в туннель в приложении «Маршрут» → «Список приложений»"),
    }

    /**
     * Текст отказа вместо прежнего «верните оранжевые в туннель», который врал и
     * в локальном режиме (там оранжевых нет), и когда приложения просто не
     * установлены. Совет зависит от причины: если причин несколько, он называет
     * действие для каждой.
     */
    private fun emptyWhitelistMessage(
        hasServerRule: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
        orangeEnabled: Set<String>,
        transportPackages: Set<String>,
        isInstalled: (String) -> Boolean,
    ): String {
        if (rulePackages.isEmpty()) {
            return "Whitelist пуст: выберите приложения, которые должны идти через туннель"
        }
        val installedRule = rulePackages.filter(isInstalled)
        if (installedRule.isEmpty()) {
            return if (hasServerRule) {
                "Whitelist пуст: ни одно приложение из правила сервера не установлено на устройстве"
            } else {
                "Whitelist пуст: ни одно выбранное приложение не установлено на устройстве"
            }
        }
        val reasons = buildList {
            if (installedRule.any { it in preset.red }) {
                add("есть приложения, которые всегда мимо туннеля" to Fix.SERVER)
            }
            if (installedRule.any { it in preset.orange && it !in preset.red && it !in orangeEnabled }) {
                add("оранжевые приложения не разрешены пользователем" to Fix.USER)
            }
            if (installedRule.all { it in transportPackages }) {
                add("все выбранные приложения — транспортные пакеты CSQTT" to Fix.SERVER)
            }
        }
        val effectiveReasons = reasons.ifEmpty {
            listOf("выбранные приложения не могут идти через туннель" to Fix.SERVER)
        }
        val detail = effectiveReasons.joinToString("; ") { it.first }
        // Локальный режим не лечится правкой серверного правила, поэтому совет
        // про сервер в нём не появляется вовсе.
        val advice = effectiveReasons
            .map { it.second }
            .filter { hasServerRule || it != Fix.SERVER }
            .distinct()
            .joinToString("; ") { it.advice }
        return if (advice.isEmpty()) {
            "Whitelist пуст: $detail"
        } else {
            "Whitelist пуст: $detail. $advice"
        }
    }
}

