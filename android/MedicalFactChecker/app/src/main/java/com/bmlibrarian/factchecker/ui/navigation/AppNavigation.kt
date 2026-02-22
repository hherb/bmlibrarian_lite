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

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.bmlibrarian.factchecker.ui.factcheck.FactCheckScreen
import com.bmlibrarian.factchecker.ui.fulltext.FullTextScreen
import com.bmlibrarian.factchecker.ui.history.HistoryScreen
import com.bmlibrarian.factchecker.ui.onboarding.OnboardingScreen
import com.bmlibrarian.factchecker.ui.report.ReportScreen
import com.bmlibrarian.factchecker.ui.settings.SettingsScreen
import com.bmlibrarian.factchecker.ui.settings.SettingsViewModel

/**
 * Main navigation component for MedicalFactChecker.
 *
 * Provides bottom navigation with four tabs:
 * - Check: Main fact-checking flow
 * - Report: View generated evidence reports
 * - History: Browse past sessions
 * - Settings: App configuration
 *
 * Shows onboarding screen on first launch before the main app.
 *
 * Uses Jetpack Compose Navigation for screen management.
 */
@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    // Get settings to check onboarding state
    val settingsViewModel: SettingsViewModel = hiltViewModel()
    val isSettingsLoaded by settingsViewModel.isSettingsLoaded.collectAsState()
    val settings by settingsViewModel.settings.collectAsState()

    // Show loading indicator while settings are being loaded from disk
    if (!isSettingsLoaded) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            CircularProgressIndicator()
        }
        return
    }

    val isOnboardingComplete = settings.hasCompletedOnboarding

    // Determine if we should show bottom navigation
    // Only show when we have a valid destination AND it's not onboarding
    val showBottomNav = currentDestination != null &&
        currentDestination.route != NavRoute.Onboarding.route

    Scaffold(
        bottomBar = {
            // Only show bottom nav when not in onboarding
            if (showBottomNav) {
                NavigationBar {
                    NavRoute.bottomNavItems.forEach { navItem ->
                        val itemRoute = navItem.route
                        val selected = currentDestination?.hierarchy?.any {
                            // Match on base route for Report to handle parameterized routes
                            it.route?.startsWith(itemRoute) == true
                        } == true

                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                navController.navigate(itemRoute) {
                                    // Pop up to the start destination to avoid building
                                    // up a large back stack
                                    popUpTo(NavRoute.FactCheck.route) {
                                        saveState = true
                                    }
                                    // Avoid multiple copies of the same destination
                                    launchSingleTop = true
                                    // Restore state when reselecting a previously selected item
                                    restoreState = true
                                }
                            },
                            icon = {
                                Icon(
                                    imageVector = if (selected) navItem.selectedIcon else navItem.unselectedIcon,
                                    contentDescription = navItem.title
                                )
                            },
                            label = { Text(navItem.title) }
                        )
                    }
                }
            }
        }
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = if (isOnboardingComplete) NavRoute.FactCheck.route else NavRoute.Onboarding.route,
            modifier = Modifier.padding(paddingValues)
        ) {
            // Onboarding screen (shown on first launch)
            composable(NavRoute.Onboarding.route) {
                OnboardingScreen(
                    onComplete = {
                        settingsViewModel.completeOnboarding()
                        navController.navigate(NavRoute.FactCheck.route) {
                            // Remove onboarding from back stack
                            popUpTo(NavRoute.Onboarding.route) { inclusive = true }
                        }
                    }
                )
            }

            // FactCheck screen with optional arguments for restoring or fetching more
            composable(
                route = NavRoute.FactCheck.routeWithArgs,
                arguments = listOf(
                    navArgument(NavRoute.FactCheck.ARG_SESSION_ID) {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                    navArgument(NavRoute.FactCheck.ARG_FETCH_MORE) {
                        type = NavType.BoolType
                        defaultValue = false
                    }
                )
            ) { backStackEntry ->
                val sessionId = backStackEntry.arguments?.getString(NavRoute.FactCheck.ARG_SESSION_ID)
                val fetchMore = backStackEntry.arguments?.getBoolean(NavRoute.FactCheck.ARG_FETCH_MORE) ?: false
                FactCheckScreen(
                    sessionIdToRestore = sessionId,
                    fetchMoreOnLoad = fetchMore,
                    onNavigateToReport = {
                        navController.navigate(NavRoute.Report.route) {
                            popUpTo(NavRoute.FactCheck.route) {
                                saveState = true
                            }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    onNavigateToFullText = { documentId ->
                        navController.navigate(NavRoute.FullText.createRoute(documentId))
                    }
                )
            }

            // Report screen with optional sessionId argument
            composable(
                route = NavRoute.Report.routeWithArgs,
                arguments = listOf(
                    navArgument(NavRoute.Report.ARG_SESSION_ID) {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    }
                )
            ) { backStackEntry ->
                val sessionId = backStackEntry.arguments?.getString(NavRoute.Report.ARG_SESSION_ID)
                ReportScreen(
                    sessionId = sessionId,
                    onNavigateToFullText = { documentId ->
                        navController.navigate(NavRoute.FullText.createRoute(documentId))
                    },
                    onRequestMoreEvidence = {
                        // Navigate to FactCheck with fetchMore flag to trigger evidence fetch
                        navController.navigate(NavRoute.FactCheck.createRoute(fetchMore = true)) {
                            popUpTo(NavRoute.FactCheck.route) {
                                saveState = false
                            }
                            launchSingleTop = true
                            restoreState = false
                        }
                    }
                )
            }

            composable(NavRoute.History.route) {
                HistoryScreen(
                    onSessionClick = { sessionId ->
                        // Navigate to FactCheck to restore session (like iOS behavior)
                        // This displays the scored documents and allows resuming search
                        navController.navigate(NavRoute.FactCheck.createRoute(sessionId)) {
                            popUpTo(NavRoute.FactCheck.route) {
                                saveState = false
                            }
                            launchSingleTop = true
                            restoreState = false
                        }
                    }
                )
            }

            composable(NavRoute.Settings.route) {
                SettingsScreen()
            }

            // Full-text viewer screen
            composable(
                route = NavRoute.FullText.routeWithArgs,
                arguments = listOf(
                    navArgument(NavRoute.FullText.ARG_DOCUMENT_ID) {
                        type = NavType.StringType
                    }
                )
            ) { backStackEntry ->
                val documentId = backStackEntry.arguments?.getString(NavRoute.FullText.ARG_DOCUMENT_ID) ?: ""
                FullTextScreen(
                    documentId = documentId,
                    onNavigateBack = { navController.popBackStack() }
                )
            }
        }
    }
}
