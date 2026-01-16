package com.bmlibrarian.factchecker.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Navigation routes for the app.
 *
 * Defines all navigation destinations with their route strings, display titles,
 * and icons for the bottom navigation bar.
 */
sealed class NavRoute(
    val route: String,
    val title: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector
) {
    /**
     * Main fact-checking screen.
     */
    data object FactCheck : NavRoute(
        route = "factcheck",
        title = "Check",
        selectedIcon = Icons.Filled.CheckCircle,
        unselectedIcon = Icons.Outlined.CheckCircle
    )

    /**
     * Evidence report display screen.
     */
    data object Report : NavRoute(
        route = "report",
        title = "Report",
        selectedIcon = Icons.Filled.Description,
        unselectedIcon = Icons.Outlined.Description
    )

    /**
     * Session history screen.
     */
    data object History : NavRoute(
        route = "history",
        title = "History",
        selectedIcon = Icons.Filled.History,
        unselectedIcon = Icons.Outlined.History
    )

    /**
     * Settings and configuration screen.
     */
    data object Settings : NavRoute(
        route = "settings",
        title = "Settings",
        selectedIcon = Icons.Filled.Settings,
        unselectedIcon = Icons.Outlined.Settings
    )

    companion object {
        /**
         * Items to display in the bottom navigation bar.
         */
        val bottomNavItems = listOf(FactCheck, Report, History, Settings)
    }
}
