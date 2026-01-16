package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.ui.theme.scoreColor
import com.bmlibrarian.factchecker.util.Constants

/**
 * Bottom sheet showing detailed document information.
 *
 * Displays full document metadata including title, authors, journal,
 * identifiers, relevance score, and abstract. Provides actions to
 * view the document on PubMed or dismiss the sheet.
 *
 * @param document The document to display details for
 * @param onOpenInPubMed Callback when "Open in PubMed" is clicked
 * @param onDismiss Callback when the sheet should be dismissed
 * @param modifier Modifier for customizing the component
 */
@Composable
fun DocumentDetailSheet(
    document: DocumentEntity,
    onOpenInPubMed: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(Constants.UI_CARD_PADDING.dp)
            .verticalScroll(rememberScrollState())
    ) {
        // Title
        Text(
            text = document.title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Authors
        Text(
            text = document.formattedAuthors,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Journal and year
        Row {
            document.journal?.let { journal ->
                Text(
                    text = journal,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            document.publicationYear?.let { year ->
                Text(
                    text = " ($year)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Identifiers row
        Row(
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_SECTION_SPACING.dp)
        ) {
            document.pmid?.let { pmid ->
                Text(
                    text = "PMID: $pmid",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            document.doi?.let { doi ->
                Text(
                    text = "DOI: $doi",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Relevance score
        document.relevanceScore?.let { score ->
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Row {
                Text(
                    text = "Relevance Score: ",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "$score/5",
                    style = MaterialTheme.typography.labelLarge,
                    color = scoreColor(score)
                )
            }

            // Score rationale
            document.scoreRationale?.let { rationale ->
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                Text(
                    text = rationale,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Abstract
        document.abstractText?.let { abstract ->
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "Abstract",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = abstract,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface
            )
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Action buttons
        Row(
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            OutlinedButton(
                onClick = onDismiss,
                modifier = Modifier.weight(1f)
            ) {
                Text("Close")
            }

            document.pmid?.let { pmid ->
                Button(
                    onClick = { onOpenInPubMed(pmid) },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        imageVector = Icons.Default.OpenInNew,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))
                    Text("PubMed")
                }
            }
        }

        // Bottom padding for navigation bar
        Spacer(modifier = Modifier.height(Constants.UI_NAVIGATION_BAR_PADDING.dp))
    }
}

@Preview(showBackground = true)
@Composable
private fun DocumentDetailSheetPreview() {
    MedicalFactCheckerTheme {
        DocumentDetailSheet(
            document = DocumentEntity(
                sessionId = "session-1",
                pmid = "12345678",
                doi = "10.1234/example.2024",
                title = "Effect of Regular Exercise on Cardiovascular Health: A Randomized Controlled Trial",
                abstractText = "Background: Physical activity has been associated with reduced cardiovascular risk. " +
                    "We conducted a randomized controlled trial to evaluate the effects of regular exercise. " +
                    "Methods: 500 participants were randomized to exercise or control groups. " +
                    "Results: The exercise group showed significant improvements in cardiovascular outcomes. " +
                    "Conclusions: Regular exercise provides substantial cardiovascular benefits.",
                authors = listOf("Smith J", "Johnson M", "Williams K", "Brown R"),
                journal = "New England Journal of Medicine",
                publicationYear = 2024,
                relevanceScore = 5,
                scoreRationale = "Highly relevant RCT directly addressing the claim with strong methodology and clear results."
            ),
            onOpenInPubMed = {},
            onDismiss = {}
        )
    }
}
