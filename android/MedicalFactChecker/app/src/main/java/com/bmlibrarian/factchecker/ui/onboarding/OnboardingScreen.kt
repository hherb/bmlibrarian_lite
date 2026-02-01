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

package com.bmlibrarian.factchecker.ui.onboarding

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Redeem
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.launch

/**
 * Data class representing a single onboarding page.
 *
 * @property icon The icon to display
 * @property title The page title
 * @property description The page description text
 */
private data class OnboardingPage(
    val icon: ImageVector,
    val title: String,
    val description: String
)

/** All onboarding pages with their content. */
private val onboardingPages = listOf(
    OnboardingPage(
        icon = Icons.Default.Verified,
        title = "Welcome to Medical Fact Checker",
        description = "Evaluate medical claims using peer-reviewed biomedical literature. " +
            "Get evidence-based verdicts backed by scientific citations."
    ),
    OnboardingPage(
        icon = Icons.AutoMirrored.Filled.Article,
        title = "Enter Your Claim",
        description = "Type any medical or health claim you want to verify. For example:\n\n" +
            "\"Vitamin D supplementation reduces COVID-19 severity\"\n\n" +
            "\"Exercise helps prevent Alzheimer's disease\""
    ),
    OnboardingPage(
        icon = Icons.Default.Search,
        title = "AI-Powered Search",
        description = "Your claim is converted to optimized search queries and sent to " +
            "PubMed and Europe PMC—databases with over 36 million biomedical citations."
    ),
    OnboardingPage(
        icon = Icons.Default.Psychology,
        title = "Intelligent Scoring",
        description = "Each retrieved article is scored 1-5 for relevance by AI. " +
            "Key supporting or refuting passages are extracted with citations."
    ),
    OnboardingPage(
        icon = Icons.Default.Description,
        title = "Evidence Report",
        description = "Get a detailed verdict (Supported, Likely Supported, Unclear, " +
            "Likely Refuted, or Refuted) with a summary explaining the evidence."
    ),
    OnboardingPage(
        icon = Icons.Default.Key,
        title = "API Keys Required",
        description = "This app uses cloud AI services that require an API key. " +
            "Your key is stored securely on your device and never shared."
    ),
    OnboardingPage(
        icon = Icons.Default.AttachMoney,
        title = "Cost-Effective",
        description = "Each fact-check typically costs \$0.01-\$0.05 depending on the model. " +
            "Set budget limits to control spending. Embedding scoring is free (on-device)."
    ),
    OnboardingPage(
        icon = Icons.Default.Redeem,
        title = "Free Options Available",
        description = "Start free with Mistral's API (free tier available) or run locally " +
            "with Ollama. No credit card required for basic usage."
    ),
    OnboardingPage(
        icon = Icons.Default.Settings,
        title = "Get Started",
        description = "To begin:\n\n" +
            "1. Go to Settings\n" +
            "2. Select your LLM provider\n" +
            "3. Enter your API key\n" +
            "4. Start fact-checking!"
    )
)

/**
 * Onboarding screen with paged walkthrough.
 *
 * Guides new users through the app features with 9 pages covering
 * the workflow, pricing, and setup instructions.
 *
 * @param onComplete Callback when onboarding is completed
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OnboardingScreen(
    onComplete: () -> Unit
) {
    val pagerState = rememberPagerState(pageCount = { onboardingPages.size })
    val coroutineScope = rememberCoroutineScope()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(Constants.UI_SCREEN_PADDING.dp)
    ) {
        // Skip button (except on last page)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End
        ) {
            if (pagerState.currentPage < onboardingPages.size - 1) {
                TextButton(onClick = onComplete) {
                    Text("Skip")
                }
            } else {
                // Placeholder for alignment
                Spacer(modifier = Modifier.height(Constants.ONBOARDING_SKIP_BUTTON_HEIGHT.dp))
            }
        }

        // Pager content
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f)
        ) { page ->
            OnboardingPageContent(page = onboardingPages[page])
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Page indicator dots
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center
        ) {
            repeat(onboardingPages.size) { index ->
                val isSelected = pagerState.currentPage == index
                Box(
                    modifier = Modifier
                        .padding(horizontal = Constants.ONBOARDING_DOT_SPACING.dp)
                        .size(
                            if (isSelected) {
                                Constants.ONBOARDING_DOT_SIZE_SELECTED.dp
                            } else {
                                Constants.ONBOARDING_DOT_SIZE_UNSELECTED.dp
                            }
                        )
                        .clip(CircleShape)
                        .background(
                            if (isSelected) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurface.copy(
                                    alpha = Constants.ONBOARDING_DOT_UNSELECTED_ALPHA
                                )
                            }
                        )
                )
            }
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Navigation buttons
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
        ) {
            // Back button (except on first page)
            if (pagerState.currentPage > 0) {
                OutlinedButton(
                    onClick = {
                        coroutineScope.launch {
                            pagerState.animateScrollToPage(pagerState.currentPage - 1)
                        }
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Back")
                }
            } else {
                Spacer(modifier = Modifier.weight(1f))
            }

            // Next/Get Started button
            Button(
                onClick = {
                    if (pagerState.currentPage < onboardingPages.size - 1) {
                        coroutineScope.launch {
                            pagerState.animateScrollToPage(pagerState.currentPage + 1)
                        }
                    } else {
                        onComplete()
                    }
                },
                modifier = Modifier.weight(1f)
            ) {
                Text(
                    if (pagerState.currentPage < onboardingPages.size - 1) "Next" else "Get Started"
                )
            }
        }
    }
}

/**
 * Content for a single onboarding page.
 *
 * Displays the icon with gradient, title, and description.
 *
 * @param page The page data to display
 */
@Composable
private fun OnboardingPageContent(page: OnboardingPage) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = Constants.UI_SCREEN_PADDING.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // Icon with gradient background
        Box(
            modifier = Modifier
                .size(Constants.ONBOARDING_ICON_CONTAINER_SIZE.dp)
                .clip(CircleShape)
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            MaterialTheme.colorScheme.primary.copy(
                                alpha = Constants.ONBOARDING_GRADIENT_ALPHA
                            ),
                            MaterialTheme.colorScheme.tertiary.copy(
                                alpha = Constants.ONBOARDING_GRADIENT_ALPHA
                            )
                        )
                    )
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = page.icon,
                contentDescription = null,
                modifier = Modifier.size(Constants.ONBOARDING_ICON_SIZE.dp),
                tint = MaterialTheme.colorScheme.onPrimary
            )
        }

        Spacer(modifier = Modifier.height(Constants.UI_PLACEHOLDER_PADDING.dp))

        // Title
        Text(
            text = page.title,
            style = MaterialTheme.typography.headlineSmall,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Description
        Text(
            text = page.description,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
