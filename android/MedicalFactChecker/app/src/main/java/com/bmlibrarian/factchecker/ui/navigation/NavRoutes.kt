/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

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
     *
     * Supports an optional sessionId argument for restoring sessions from history.
     * When sessionId is null, displays the normal fact-check input screen.
     */
    data object FactCheck : NavRoute(
        route = "factcheck",
        title = "Check",
        selectedIcon = Icons.Filled.CheckCircle,
        unselectedIcon = Icons.Outlined.CheckCircle
    ) {
        /** Route pattern with optional sessionId argument for session restoration. */
        const val routeWithArgs = "factcheck?sessionId={sessionId}"

        /** Argument key for session ID to restore. */
        const val ARG_SESSION_ID = "sessionId"

        /**
         * Creates a route with the specified session ID for restoration.
         *
         * @param sessionId The session ID to restore, or null for normal fact-check
         * @return The navigation route string
         */
        fun createRoute(sessionId: String? = null): String {
            return if (sessionId != null) {
                "factcheck?sessionId=$sessionId"
            } else {
                route
            }
        }
    }

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

    /**
     * Onboarding screen for new users.
     * Not shown in bottom navigation.
     */
    data object Onboarding : NavRoute(
        route = "onboarding",
        title = "Welcome",
        selectedIcon = Icons.Filled.CheckCircle, // Not used in nav bar
        unselectedIcon = Icons.Outlined.CheckCircle // Not used in nav bar
    )

    /**
     * Full-text viewer screen.
     * Not shown in bottom navigation.
     */
    data object FullText : NavRoute(
        route = "fulltext",
        title = "Full Text",
        selectedIcon = Icons.Filled.Description, // Not used in nav bar
        unselectedIcon = Icons.Outlined.Description // Not used in nav bar
    ) {
        /** Route pattern with required documentId argument. */
        const val routeWithArgs = "fulltext/{documentId}"

        /** Argument key for document ID. */
        const val ARG_DOCUMENT_ID = "documentId"

        /**
         * Creates a route with the specified document ID.
         *
         * @param documentId The document ID to view
         * @return The navigation route string
         */
        fun createRoute(documentId: String): String {
            return "fulltext/$documentId"
        }
    }

    companion object {
        /**
         * Items to display in the bottom navigation bar.
         * Uses lazy initialization to avoid Kotlin data object initialization order issues.
         */
        val bottomNavItems: List<NavRoute> by lazy {
            listOf(FactCheck, Report, History, Settings)
        }
    }
}
