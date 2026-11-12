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
     * белый режим серверного правила, набор правила непуст, но ни один пакет
     * не установлен в нашем пользователе (приватное пространство Android обычному
     * приложению «не видно»). Отличить его от «правило перечислило приложения
     * другого устройства» нельзя — оба случая трактуются одинаково, осознанно.
     * Вход — СЫРОЕ правило, до вычитания чёрного списка пользователя: иначе
     * исключение последнего видимого пакета превратило бы видимое правило в
     * «невидимое», включило device-wide план и расширило покрытие. Наличие
     * серверного правила гейтит вызывающий (в build — по hasServerRule;
     * cardCounts существует только под правилом).
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
 * [rulePackages] — эффективный набор, для белого правила уже без исключённых
 * пользователем. [serverRulePackages] — сырое правило: по нему, а не по
 * эффективному набору, оценивается подмена. Иначе исключение последнего
 * видимого пакета делало бы видимое правило «невидимым», включало device-wide
 * план и расширяло покрытие. [userExcluded] — чёрный список пользователя: под
 * подменой он вычитается из device-wide плана, [userEnabled] сильнее него.
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
        userExcluded: Set<String> = emptySet(),
        serverRulePackages: Set<String> = rulePackages,
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
        // Подмена (спека §2, §7.8): белый набор СЫРОГО правила непуст, но ни
        // один его пакет не установлен — правило применяется ко всем
        // приложениям, кроме пресета, транспорта и исключений пользователя.
        // Предикат оценивается по сырому правилу до вычитания чёрного списка:
        // иначе исключение последнего видимого пакета расширило бы покрытие до
        // device-wide. Проверка стоит до ветки Allow: иначе установленный
        // возвращённый оранжевый сузил бы план до одного приложения, пока
        // карточка и подпись в диалоге показывают device-wide.
        val substituted = hasServerRule &&
            AppRoutingPolicy.isServerWhitelistInvisible(isWhite, serverRulePackages, isInstalled)
        // Пользователь исключил все установленные приложения правила, и хотя бы
        // одно из них могло бы идти в туннель, — это отказ с его собственной
        // причиной. Красный, невозвращённый оранжевый и транспорт исключены и
        // без пользователя: снятие исключения их не вернёт, поэтому причина
        // остаётся за ветками ниже. Ветка Allow срабатывает раньше, поэтому
        // установленный возвращённый оранжевый по-прежнему держит туннель.
        val userExcludedInstalled = (serverRulePackages intersect userExcluded)
            .filter(isInstalled)
            .filter { pkg ->
                pkg !in preset.red &&
                    (pkg !in preset.orange || pkg in orangeEnabled) &&
                    pkg !in transportPackages
            }
            .toSet()
        val ruleEmptiedByUser = hasServerRule && isWhite &&
            userExcludedInstalled.isNotEmpty() &&
            (serverRulePackages - userExcluded).none(isInstalled)
        // Пресет, транспорт и само приложение идут мимо туннеля; исключения
        // пользователя добавляются к device-wide плану, но возвращённый
        // оранжевый сильнее чёрного списка.
        val disallowed = LinkedHashSet<String>()
        disallowed += transportPackages - selfPackage
        disallowed += (AppRoutingPolicy.forcedExcluded(preset) + (preset.orange - orangeEnabled))
            .filter { it !in transportPackages }
        disallowed += userExcluded - orangeEnabled - transportPackages - selfPackage
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
                ruleEmptiedByUser = ruleEmptiedByUser,
                serverRulePackages = serverRulePackages,
                userExcludedInstalled = userExcludedInstalled,
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
        USER("Верните оранжевые приложения в туннель: «Настройки» → «Маршрутизация приложений» → «Список приложений»"),
        USER_EXCLUSIONS("Снимите исключения: «Настройки» → «Список приложений»"),
    }

    /**
     * Текст отказа вместо прежнего «верните оранжевые в туннель», который врал и
     * в локальном режиме (там оранжевых нет), и когда приложения просто не
     * установлены. Совет зависит от причины: если причин несколько, он называет
     * действие для каждой.
     *
     * Пустой список — это «никто», а не «все» (спека §7.9), одинаково в обоих
     * режимах. Если пользователь исключил все установленные приложения правила
     * и хотя бы одно из них могло бы идти в туннель, отказ называет именно его
     * действие: совет «добавьте в белый список» врал бы — белый список под
     * правилом недоступен. Когда исключение ничего не могло изменить (красный,
     * невозвращённый оранжевый, транспорт), причина остаётся за пресетом или
     * оператором. Под правилом причины считаются по СЫРОМУ набору: эффективный
     * может быть пуст из-за вычитания, и «правило пусто» было бы неправдой.
     *
     * Пустой серверный белый список обязан назвать режим правила: после
     * терминального отказа UI теряет правило и падает в режим профиля, и без
     * этого пользователь не понимает, что чинить надо на сервере. Под правилом
     * белый список недоступен, поэтому совет про заполнение списка врал бы.
     */
    private fun emptyWhitelistMessage(
        hasServerRule: Boolean,
        isWhite: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
        orangeEnabled: Set<String>,
        transportPackages: Set<String>,
        isInstalled: (String) -> Boolean,
        ruleEmptiedByUser: Boolean,
        serverRulePackages: Set<String>,
        userExcludedInstalled: Set<String>,
    ): String {
        if (ruleEmptiedByUser) {
            return "Whitelist пуст: вы исключили все установленные приложения из правила " +
                "сервера — снимите исключения в списке приложений"
        }
        if (!hasServerRule && rulePackages.isEmpty()) {
            return "Whitelist пуст: выберите приложения, которые должны идти через туннель"
        }
        if (hasServerRule && serverRulePackages.isEmpty()) {
            val mode = if (isWhite) "белом" else "чёрном"
            return "Whitelist пуст: правило сервера задано в $mode режиме и пусто — " +
                "поправьте правило на сервере"
        }
        // Сырой набор под правилом: эффективный пуст, если пользователь вычел
        // из него пакеты, которые и без него не могли идти в туннель.
        val diagnosed = if (hasServerRule) serverRulePackages else rulePackages
        val installedRule = diagnosed.filter(isInstalled)
        if (installedRule.isEmpty()) {
            return "Whitelist пуст: ни одно выбранное приложение не установлено на устройстве"
        }
        // В смешанном случае (в правиле остался ещё и красный пакет) причина
        // пользователя не должна теряться за серверной.
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
            if (userExcludedInstalled.isNotEmpty()) {
                add("вы исключили установленные приложения правила" to Fix.USER_EXCLUSIONS)
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

