package com.bmlibrarian.factchecker.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.bmlibrarian.factchecker.ui.factcheck.FactCheckScreen
import com.bmlibrarian.factchecker.ui.history.HistoryScreen
import com.bmlibrarian.factchecker.ui.report.ReportScreen
import com.bmlibrarian.factchecker.ui.settings.SettingsScreen

/**
 * Main navigation component for MedicalFactChecker.
 *
 * Provides bottom navigation with four tabs:
 * - Check: Main fact-checking flow
 * - Report: View generated evidence reports
 * - History: Browse past sessions
 * - Settings: App configuration
 *
 * Uses Jetpack Compose Navigation for screen management.
 */
@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavRoute.bottomNavItems.forEach { navItem ->
                    val selected = currentDestination?.hierarchy?.any {
                        it.route == navItem.route
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
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = NavRoute.FactCheck.route,
            modifier = Modifier.padding(paddingValues)
        ) {
            composable(NavRoute.FactCheck.route) {
                FactCheckScreen(
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

            composable(NavRoute.Report.route) {
                ReportScreen()
            }

            composable(NavRoute.History.route) {
                HistoryScreen(
                    onSessionClick = { sessionId ->
                        // Navigate to report for this session
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

            composable(NavRoute.Settings.route) {
                SettingsScreen()
            }
        }
    }
}
