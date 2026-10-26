package com.csqtt.client.ui

/**
 * Visibility rules of the app list dialog.
 *
 * System applications are hidden by default. They stay visible when the user
 * turns them on explicitly, or when they carry an active rule of the current
 * routing mode — a rule must never become invisible just because the system
 * app is hidden.
 *
 * [keepVisible] holds packages that must stay visible regardless of the rules
 * right now. It is used to freeze the pinned system apps for the time the
 * dialog is open, so that unchecking a rule does not delete the row under the
 * user's finger. It never affects the ordering.
 */
internal object AppListPolicy {

    fun matchesQuery(name: String, packageName: String, query: String): Boolean {
        if (query.isBlank()) return true
        return name.contains(query, ignoreCase = true) ||
            packageName.contains(query, ignoreCase = true)
    }

    fun <T> filterApps(
        apps: List<T>,
        query: String,
        showSystemApps: Boolean,
        activeSelection: Set<String>,
        isSystem: (T) -> Boolean,
        packageName: (T) -> String,
        name: (T) -> String,
        keepVisible: Set<String> = emptySet(),
    ): List<T> {
        val visible = apps.filter { app ->
            val pkg = packageName(app)
            val matches = matchesQuery(name(app), pkg, query)
            val systemVisible = showSystemApps || pkg in activeSelection || pkg in keepVisible
            matches && (systemVisible || !isSystem(app))
        }
        return selectedApplicationsFirst(visible, activeSelection, packageName, name)
    }
}
