package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.util.Constants
import java.util.Locale

/**
 * Table showing model pricing information.
 *
 * Displays a table with model names and their input/output pricing
 * per million tokens. Shows "Free" for models with zero pricing.
 *
 * @param models List of models to display pricing for
 * @param modifier Modifier to be applied to the table container
 */
@Composable
fun ModelPricingTable(
    models: List<ModelInfo>,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        // Header row
        Row(
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "Model",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.weight(Constants.SETTINGS_PRICING_MODEL_WEIGHT)
            )
            Text(
                text = "Input",
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(Constants.SETTINGS_PRICING_VALUE_WEIGHT)
            )
            Text(
                text = "Output",
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(Constants.SETTINGS_PRICING_VALUE_WEIGHT)
            )
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = Constants.UI_ELEMENT_SPACING.dp))

        // Model rows
        models.forEach { model ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = Constants.UI_ELEMENT_SPACING_SMALL.dp)
            ) {
                Text(
                    text = model.displayName,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(Constants.SETTINGS_PRICING_MODEL_WEIGHT)
                )
                Text(
                    text = formatPrice(model.inputPricePer1M),
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.End,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(Constants.SETTINGS_PRICING_VALUE_WEIGHT)
                )
                Text(
                    text = formatPrice(model.outputPricePer1M),
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.End,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(Constants.SETTINGS_PRICING_VALUE_WEIGHT)
                )
            }
        }

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        Text(
            text = "Prices per 1M tokens in USD",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/**
 * Format a price value for display.
 *
 * Shows "Free" for zero prices, otherwise formats as currency.
 *
 * @param price The price value to format
 * @return Formatted price string
 */
private fun formatPrice(price: Double): String {
    return if (price == 0.0) {
        "Free"
    } else {
        String.format(
            Locale.US,
            "$%.${Constants.SETTINGS_BUDGET_DECIMAL_PLACES}f",
            price
        )
    }
}
