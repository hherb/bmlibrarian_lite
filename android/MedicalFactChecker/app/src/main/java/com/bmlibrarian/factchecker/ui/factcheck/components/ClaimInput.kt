package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Input component for the medical claim.
 *
 * Provides a multi-line text input for entering medical claims
 * and a submit button to start the fact-checking process.
 *
 * @param claimText Current text in the input field
 * @param onClaimTextChange Callback when text changes
 * @param onSubmit Callback when submit button is pressed
 * @param isEnabled Whether the input is enabled for interaction
 * @param modifier Modifier for the component
 */
@Composable
fun ClaimInput(
    claimText: String,
    onClaimTextChange: (String) -> Unit,
    onSubmit: () -> Unit,
    isEnabled: Boolean,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        OutlinedTextField(
            value = claimText,
            onValueChange = onClaimTextChange,
            label = { Text("Medical Claim") },
            placeholder = { Text("Enter a medical claim to fact-check...") },
            enabled = isEnabled,
            minLines = 3,
            maxLines = 5,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(12.dp))

        Button(
            onClick = onSubmit,
            enabled = isEnabled && claimText.isNotBlank(),
            modifier = Modifier.align(Alignment.End)
        ) {
            Icon(
                imageVector = Icons.Default.Search,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text("Check Claim")
        }
    }
}
