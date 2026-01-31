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

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.bmlibrarian.factchecker.ui.factcheck.FactCheckScreen
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
    val settings by settingsViewModel.settings.collectAsState()
    val isOnboardingComplete = settings.hasCompletedOnboarding

    // Determine if we should show bottom navigation
    val showBottomNav = currentDestination?.route != NavRoute.Onboarding.route

    Scaffold(
        bottomBar = {
            // Only show bottom nav when not in onboarding
            if (showBottomNav) {
                NavigationBar {
                    NavRoute.bottomNavItems.forEach { navItem ->
                        val selected = currentDestination?.hierarchy?.any {
                            // Match on base route for Report to handle parameterized routes
                            it.route?.startsWith(navItem.route) == true
                        } == true

                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                navController.navigate(navItem.route) {
                                    // Pop up to the start destination to avoid building
                                    // up a large back stack
                                    popUpTo(navController.graph.findStartDestination().id) {
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

            // FactCheck screen with optional sessionId argument for restoring from history
            composable(
                route = NavRoute.FactCheck.routeWithArgs,
                arguments = listOf(
                    navArgument(NavRoute.FactCheck.ARG_SESSION_ID) {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    }
                )
            ) { backStackEntry ->
                val sessionId = backStackEntry.arguments?.getString(NavRoute.FactCheck.ARG_SESSION_ID)
                FactCheckScreen(
                    sessionIdToRestore = sessionId,
                    onNavigateToReport = {
                        navController.navigate(NavRoute.Report.route) {
                            popUpTo(navController.graph.findStartDestination().id) {
                                saveState = true
                            }
                            launchSingleTop = true
                            restoreState = true
                        }
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
                ReportScreen(sessionId = sessionId)
            }

            composable(NavRoute.History.route) {
                HistoryScreen(
                    onSessionClick = { sessionId ->
                        // Navigate to FactCheck to restore session (like iOS behavior)
                        // This displays the scored documents and allows resuming search
                        navController.navigate(NavRoute.FactCheck.createRoute(sessionId)) {
                            popUpTo(navController.graph.findStartDestination().id) {
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
        }
    }
}
