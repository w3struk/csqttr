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
     * Подмена «на все приложения» (спека §2, §7.8 — решение владельца 2026-10-27):
     * белый режим серверного правила, эффективный набор непуст, но ни один пакет
     * не установлен в нашем пользователе (приватное пространство Android обычному
     * приложению «не видно»). Отличить его от «правило перечислило приложения
     * другого устройства» нельзя — оба случая трактуются одинаково, осознанно.
     * Набор — эффективный (правило ∪ локальный список), ровно тот, что `build`
     * получает как rulePackages; наличие серверного правила гейтит вызывающий
     * (в build — по hasServerRule; cardCounts существует только под правилом).
     * Единственный источник правды для build, cardCounts, признака подмены для
     * подписи диалога (`AppDialogPolicy.substitutionApplied`) и per-UID триггера
     * (`TunnelService.onPackageChanged` передаёт результат в overload
     * `PackageChangePolicy.needsVpnRebuild` как `planSubstituted`).
     */
    fun isServerWhitelistInvisible(
        isWhite: Boolean,
        rulePackages: Set<String>,
        isInstalled: (String) -> Boolean,
    ): Boolean =
        isWhite && rulePackages.isNotEmpty() && rulePackages.none(isInstalled)
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
     * потому что ошибка именно на этом шаге фатальна для VPN.
     *
     * @param deviceWide план покрывает всё устройство минус [packages]; в новой
     *   семантике истинно только при [substituted] — других источников
     *   device-wide нет.
     * @param substituted подмена: белый список правила непуст, но ни один пакет
     *   не установлен — правило применено ко всем приложениям, кроме пресета и
     *   транспорта (спека §7.8).
     */
    data class Disallow(
        val packages: List<String>,
        val deviceWide: Boolean = false,
        val substituted: Boolean = false,
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
        // Подмена (спека §2, §7.8): белый набор правила непуст, но ни один его
        // пакет не установлен — правило применяется ко всем приложениям, кроме
        // пресета и транспорта. Предикат оценивается по эффективному набору до
        // возвращённых оранжевых, а проверка стоит до ветки Allow: иначе
        // установленный возвращённый оранжевый сузил бы план до одного приложения,
        // пока карточка и подпись в диалоге показывают device-wide.
        val substituted = hasServerRule &&
            AppRoutingPolicy.isServerWhitelistInvisible(isWhite, rulePackages, isInstalled)
        // Пресет идёт мимо туннеля вместе со всеми остальными. Оранжевые из U не
        // исключаются — пользователь вернул их в туннель.
        val disallowed = (transportPackages - selfPackage) +
            (AppRoutingPolicy.forcedExcluded(preset) + (preset.orange - orangeEnabled))
                .filter { it !in transportPackages }
        if (substituted) {
            return VpnAppsPlan.Disallow(
                packages = disallowed.filter { it != selfPackage && isInstalled(it) },
                deviceWide = true,
                substituted = true,
            )
        }

        if (installedIncluded.isNotEmpty()) {
            return VpnAppsPlan.Allow(installedIncluded.toList())
        }

        // Пустой эффективный белый набор — отказ в обоих режимах: пустой список
        // значит «никто», а не «все» (спека §7.9).
        return VpnAppsPlan.Failure(
            emptyWhitelistMessage(
                hasServerRule = hasServerRule,
                isWhite = isWhite,
                rulePackages = rulePackages,
                preset = preset,
                orangeEnabled = orangeEnabled,
                transportPackages = transportPackages,
                isInstalled = isInstalled,
            )
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
     *
     * Пустой список — это «никто», а не «все» (спека §7.9), одинаково в обоих
     * режимах. Серверный вариант «ни одно приложение из правила не установлено»
     * недостижим: непустой невидимый набор перехватывает подмена, а пустой
     * уходит в первую ветку.
     *
     * Пустой серверный белый список обязан назвать режим правила и список,
     * который надо заполнить: после терминального отказа UI теряет правило и
     * падает в режим профиля, поэтому пользователь с чёрным профилем по
     * умолчанию правит чёрный список, а отказ повторяется. Текст — единственное,
     * что связывает его с белым списком.
     */
    private fun emptyWhitelistMessage(
        hasServerRule: Boolean,
        isWhite: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
        orangeEnabled: Set<String>,
        transportPackages: Set<String>,
        isInstalled: (String) -> Boolean,
    ): String {
        if (rulePackages.isEmpty()) {
            if (!hasServerRule) {
                return "Whitelist пуст: выберите приложения, которые должны идти через туннель"
            }
            val mode = if (isWhite) "белом" else "чёрном"
            val list = if (isWhite) "белый" else "чёрный"
            return "Whitelist пуст: правило сервера задано в $mode режиме — " +
                "добавьте приложения в $list список"
        }
        val installedRule = rulePackages.filter(isInstalled)
        if (installedRule.isEmpty()) {
            return "Whitelist пуст: ни одно выбранное приложение не установлено на устройстве"
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

