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
     *
     * Supports an optional sessionId argument for viewing specific session reports.
     * When sessionId is null, displays the most recent report.
     */
    data object Report : NavRoute(
        route = "report",
        title = "Report",
        selectedIcon = Icons.Filled.Description,
        unselectedIcon = Icons.Outlined.Description
    ) {
        /** Route pattern with optional sessionId argument. */
        const val routeWithArgs = "report?sessionId={sessionId}"

        /** Argument key for session ID. */
        const val ARG_SESSION_ID = "sessionId"

        /**
         * Creates a route with the specified session ID.
         *
         * @param sessionId The session ID to view, or null for latest report
         * @return The navigation route string
         */
        fun createRoute(sessionId: String? = null): String {
            return if (sessionId != null) {
                "report?sessionId=$sessionId"
            } else {
                route
            }
        }
    }

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
