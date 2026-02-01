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

package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.sync.SyncConstants
import com.bmlibrarian.factchecker.domain.sync.SyncStatus
import com.bmlibrarian.factchecker.domain.sync.SyncUiState
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Sync settings section for the Settings screen.
 *
 * Displays sync status, connected devices, and allows folder configuration.
 *
 * @param syncState Current sync UI state
 * @param onSelectFolder Callback when user wants to select a folder
 * @param onSyncNow Callback to trigger manual sync
 * @param onDisableSync Callback to disable sync
 */
@Composable
fun SyncSettingsSection(
    syncState: SyncUiState,
    onSelectFolder: () -> Unit,
    onSyncNow: () -> Unit,
    onDisableSync: () -> Unit,
    modifier: Modifier = Modifier
) {
    var showDisableDialog by remember { mutableStateOf(false) }

    SettingsSection(
        title = "Cross-Platform Sync",
        modifier = modifier
    ) {
        when (syncState.status) {
            SyncStatus.NOT_CONFIGURED -> {
                SyncNotConfiguredCard(onSelectFolder = onSelectFolder)
            }

            SyncStatus.IDLE,
            SyncStatus.SYNCING,
            SyncStatus.ERROR,
            SyncStatus.FOLDER_UNAVAILABLE -> {
                SyncConfiguredCard(
                    syncState = syncState,
                    onSyncNow = onSyncNow,
                    onChangeFolder = onSelectFolder,
                    onDisableSync = { showDisableDialog = true }
                )
            }
        }
    }

    // Disable confirmation dialog
    if (showDisableDialog) {
        AlertDialog(
            onDismissRequest = { showDisableDialog = false },
            title = { Text("Disable Sync?") },
            text = {
                Text(
                    "This will stop syncing data with other devices. " +
                    "Your local data will not be deleted."
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showDisableDialog = false
                        onDisableSync()
                    }
                ) {
                    Text("Disable Sync")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDisableDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}

/**
 * Card shown when sync is not configured.
 */
@Composable
private fun SyncNotConfiguredCard(
    onSelectFolder: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.CloudOff,
                contentDescription = null,
                modifier = Modifier.size(48.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = "Sync Not Configured",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Medium
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "Sync your data across devices using any folder sync service " +
                       "(Dropbox, Google Drive, iCloud, etc.)",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(16.dp))

            Button(onClick = onSelectFolder) {
                Icon(
                    imageVector = Icons.Default.Folder,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text("Select Sync Folder")
            }
        }
    }
}

/**
 * Card shown when sync is configured.
 */
@Composable
private fun SyncConfiguredCard(
    syncState: SyncUiState,
    onSyncNow: () -> Unit,
    onChangeFolder: () -> Unit,
    onDisableSync: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Status row
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SyncStatusIndicator(status = syncState.status)

                Spacer(modifier = Modifier.width(12.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = statusTitle(syncState.status),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium
                    )

                    if (syncState.lastSyncAt != null) {
                        Text(
                            text = "Last sync: ${formatTimestamp(syncState.lastSyncAt)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                // Sync now button
                IconButton(
                    onClick = onSyncNow,
                    enabled = syncState.status != SyncStatus.SYNCING
                ) {
                    if (syncState.status == SyncStatus.SYNCING) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Default.Sync,
                            contentDescription = "Sync now"
                        )
                    }
                }
            }

            // Error message
            AnimatedVisibility(
                visible = syncState.errorMessage != null,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp)
                        .background(
                            MaterialTheme.colorScheme.errorContainer,
                            RoundedCornerShape(8.dp)
                        )
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.Error,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = syncState.errorMessage ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Folder path
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Folder,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = syncState.syncFolderPath ?: "Unknown",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }

            // Connected devices
            if (syncState.connectedDevices > 0) {
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.Devices,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "${syncState.connectedDevices} other device${if (syncState.connectedDevices > 1) "s" else ""} connected",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Action buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End
            ) {
                TextButton(onClick = onDisableSync) {
                    Text("Disable Sync")
                }
                Spacer(modifier = Modifier.width(8.dp))
                OutlinedButton(onClick = onChangeFolder) {
                    Text("Change Folder")
                }
            }
        }
    }
}

/**
 * Visual indicator for sync status.
 */
@Composable
private fun SyncStatusIndicator(
    status: SyncStatus,
    modifier: Modifier = Modifier
) {
    val (color, icon) = when (status) {
        SyncStatus.NOT_CONFIGURED -> MaterialTheme.colorScheme.surfaceVariant to Icons.Default.CloudOff
        SyncStatus.IDLE -> MaterialTheme.colorScheme.primary to Icons.Default.Check
        SyncStatus.SYNCING -> MaterialTheme.colorScheme.primary to Icons.Default.Sync
        SyncStatus.ERROR -> MaterialTheme.colorScheme.error to Icons.Default.Close
        SyncStatus.FOLDER_UNAVAILABLE -> MaterialTheme.colorScheme.error to Icons.Default.CloudOff
    }

    if (status == SyncStatus.SYNCING) {
        CircularProgressIndicator(
            modifier = modifier.size(32.dp),
            strokeWidth = 3.dp
        )
    } else {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(color.copy(alpha = 0.1f))
                .padding(6.dp),
            tint = color
        )
    }
}

/**
 * Returns a user-friendly title for the sync status.
 */
private fun statusTitle(status: SyncStatus): String = when (status) {
    SyncStatus.NOT_CONFIGURED -> "Not Configured"
    SyncStatus.IDLE -> "Sync Enabled"
    SyncStatus.SYNCING -> "Syncing..."
    SyncStatus.ERROR -> "Sync Error"
    SyncStatus.FOLDER_UNAVAILABLE -> "Folder Unavailable"
}

/**
 * Formats a timestamp for display.
 *
 * @param timestamp Unix timestamp in milliseconds
 * @return Human-readable relative time string
 */
private fun formatTimestamp(timestamp: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - timestamp

    return when {
        diff < SyncConstants.ONE_MINUTE_MS -> "just now"
        diff < SyncConstants.ONE_HOUR_MS -> "${diff / SyncConstants.ONE_MINUTE_MS} min ago"
        diff < SyncConstants.ONE_DAY_MS -> "${diff / SyncConstants.ONE_HOUR_MS} hr ago"
        else -> SimpleDateFormat("MMM d, h:mm a", Locale.getDefault()).format(Date(timestamp))
    }
}

/**
 * Dialog for selecting/entering a sync folder path.
 *
 * @param currentPath Currently configured path (null if not configured)
 * @param onDismiss Called when dialog is dismissed
 * @param onConfirm Called with the selected path when user confirms
 */
@Composable
fun SyncFolderDialog(
    currentPath: String?,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var path by remember { mutableStateOf(currentPath ?: SyncConstants.DEFAULT_SYNC_FOLDER_PATH) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sync Folder") },
        text = {
            Column {
                Text(
                    text = "Enter the path to a folder synced by your preferred service " +
                           "(Dropbox, Google Drive, etc.)",
                    style = MaterialTheme.typography.bodyMedium
                )

                Spacer(modifier = Modifier.height(16.dp))

                OutlinedTextField(
                    value = path,
                    onValueChange = { path = it },
                    label = { Text("Folder Path") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = "Example paths:\n" +
                           "• /storage/emulated/0/Dropbox/BMLibrarian\n" +
                           "• /storage/emulated/0/Download/Sync",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(path) },
                enabled = path.isNotBlank()
            ) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
