package com.csqtt.client.ui

import com.csqtt.client.AppRoutingPolicy
import com.csqtt.client.PresetApps

internal enum class AppSectionSource { RED, SERVER, ORANGE, USER }

internal data class AppDialogSection<T>(
    val title: String,
    val source: AppSectionSource,
    val rows: List<T>,
    val total: Int,
)

/** Чекбокс и доступность строки под активным правилом сервера. */
internal data class AppRowState(val checked: Boolean, val enabled: Boolean)

internal object AppDialogPolicy {

    /**
     * Состояние строки под правилом: отмечено = «мимо туннеля».
     *
     * Красный пресет — всегда мимо и заперт. Приложения правила под чёрным
     * правилом уже мимо и заперты, под белым — кликабельны и вычитаются из
     * туннеля. Оранжевые переключаются в обе стороны прежним механизмом.
     * Обычные приложения под чёрным правилом добавляются в чёрный список; под
     * белым они уже мимо и заперты — вернуть их в туннель нельзя. Под подменой
     * «на все приложения» обычные приложения фактически идут через туннель,
     * поэтому строка показывает реальный маршрут и остаётся кликабельной:
     * исключение пользователя действует и в плане «на все приложения».
     */
    fun rowState(
        source: AppSectionSource,
        isWhitelist: Boolean,
        packageName: String,
        userBlack: Set<String>,
        orangeTunnelEnabled: Set<String>,
        substituted: Boolean = false,
    ): AppRowState = when (source) {
        AppSectionSource.RED -> AppRowState(checked = true, enabled = false)
        AppSectionSource.SERVER ->
            if (isWhitelist) AppRowState(checked = packageName in userBlack, enabled = true)
            else AppRowState(checked = true, enabled = false)
        AppSectionSource.ORANGE ->
            AppRowState(checked = packageName !in orangeTunnelEnabled, enabled = true)
        AppSectionSource.USER ->
            if (isWhitelist && !substituted) AppRowState(checked = true, enabled = false)
            else AppRowState(checked = packageName in userBlack, enabled = true)
    }

    /**
     * Подмена «правило на все приложения» для подписи диалога.
     *
     * Считается здесь, а не в диалоге, потому что диалог получает уже
     * отфильтрованный поиском список: выводить из него установленность нельзя —
     * любое расхождение фильтра с пакетами правила превращало бы видимый набор
     * в «невидимый» и подпись врала бы. [installedPackages] — авторитетный
     * набор из `PackageManager` (включая транспорт и сам CSQTT), [rulePackages] —
     * СЫРОЕ правило, до вычитания чёрного списка пользователя: исключение
     * последнего видимого пакета не должно превращать видимое правило в
     * подмену.
     *
     * Пустой [installedPackages] — это первый кадр или неудачная первичная
     * загрузка, а не «ничего не установлено»: в этом состоянии карточка честно
     * пишет «список приложений недоступен», и подпись не должна утверждать
     * подмену. Тот же признак (`installedPackages.isEmpty()`) гасит и счётчики
     * карточки.
     */
    fun substitutionApplied(
        serverLocked: Boolean,
        isWhite: Boolean,
        rulePackages: Set<String>,
        installedPackages: Set<String>,
    ): Boolean = installedPackages.isNotEmpty() && serverLocked && AppRoutingPolicy.isServerWhitelistInvisible(
        isWhite = isWhite,
        rulePackages = rulePackages,
        isInstalled = { it in installedPackages },
    )

    fun <T> buildSections(
        apps: List<T>,
        packageName: (T) -> String,
        ruleActive: Boolean,
        rulePackages: Set<String>,
        preset: PresetApps,
    ): List<AppDialogSection<T>> {
        if (!ruleActive) {
            return listOf(
                AppDialogSection(
                    title = "",
                    source = AppSectionSource.USER,
                    rows = apps,
                    total = apps.size,
                ),
            )
        }

        val result = mutableListOf<AppDialogSection<T>>()

        if (preset.red.isNotEmpty()) {
            val redRows = apps.filter { packageName(it) in preset.red }
            result.add(
                AppDialogSection(
                    title = "Всегда мимо туннеля",
                    source = AppSectionSource.RED,
                    rows = redRows,
                    total = preset.red.size,
                ),
            )
        }

        if (rulePackages.isNotEmpty()) {
            val serverAllowedPackages = rulePackages - preset.all
            val serverRows = apps.filter { packageName(it) in serverAllowedPackages }
            result.add(
                AppDialogSection(
                    title = "Правило сервера",
                    source = AppSectionSource.SERVER,
                    rows = serverRows,
                    total = rulePackages.size,
                ),
            )
        }

        if (preset.orange.isNotEmpty()) {
            val orangeAllowedPackages = preset.orange - preset.red
            val orangeRows = apps.filter { packageName(it) in orangeAllowedPackages }
            result.add(
                AppDialogSection(
                    title = "Можно отключить",
                    source = AppSectionSource.ORANGE,
                    rows = orangeRows,
                    total = preset.orange.size,
                ),
            )
        }

        val userRows = apps.filter {
            val pkg = packageName(it)
            pkg !in preset.all && pkg !in rulePackages
        }
        result.add(
            AppDialogSection(
                title = "",
                source = AppSectionSource.USER,
                rows = userRows,
                total = userRows.size,
            ),
        )

        return result
    }
}
