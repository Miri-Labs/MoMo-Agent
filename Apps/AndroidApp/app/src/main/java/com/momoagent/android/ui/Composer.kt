package com.momoagent.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.momoagent.android.R
import com.momoagent.android.data.AgentAttachment

@Composable
fun Composer(
    draft: String,
    attachments: List<AgentAttachment>,
    onDraftChange: (String) -> Unit,
    onAdd: () -> Unit,
    onRemove: (String) -> Unit,
    onSend: () -> Unit,
    onMic: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalMoMoPalette.current
    val canSend = draft.isNotBlank() || attachments.isNotEmpty()
    GlassSurface(
        modifier = modifier
            .fillMaxWidth()
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        shape = RoundedCornerShape(28.dp),
        contentPadding = PaddingValues(4.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            if (attachments.isNotEmpty()) {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
                ) {
                    items(attachments, key = { it.id }) { item ->
                        AttachmentChip(item = item, onRemove = { onRemove(item.id) })
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onAdd) {
                    Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.chat_add_attachment),
                        tint = palette.ink, modifier = Modifier.size(22.dp))
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    textStyle = MoMoType.body.copy(color = palette.ink),
                    cursorBrush = SolidColor(palette.ink),
                    maxLines = 5,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onSend() }),
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 4.dp, vertical = 12.dp),
                    decorationBox = { inner ->
                        Box {
                            if (draft.isEmpty()) {
                                Text(
                                    text = stringResource(R.string.chat_prompt),
                                    style = MoMoType.body,
                                    color = palette.muted,
                                )
                            }
                            inner()
                        }
                    },
                )
                if (canSend) {
                    IconButton(onClick = onSend) {
                        Icon(Icons.Filled.ArrowUpward, contentDescription = stringResource(R.string.chat_send),
                            tint = palette.canvas,
                            modifier = Modifier.background(palette.ink, CircleShape).padding(9.dp).size(20.dp))
                    }
                } else {
                    IconButton(onClick = onMic) {
                        Icon(Icons.Filled.Mic, contentDescription = stringResource(R.string.chat_voice),
                            tint = palette.muted, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachmentChip(item: AgentAttachment, onRemove: () -> Unit) {
    val palette = LocalMoMoPalette.current
    val image = remember(item.preview) { decodePreview(item.preview) }
    if (image != null) {
        Box(modifier = Modifier.size(56.dp)) {
            Image(
                bitmap = image.asImageBitmap(),
                contentDescription = item.name,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(20.dp)
                    .background(palette.ink.copy(alpha = 0.8f), RoundedCornerShape(10.dp))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onRemove,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.chat_remove_attachment),
                    tint = palette.canvas,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    } else {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .height(40.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(palette.surface.copy(alpha = 0.65f))
                .border(0.75.dp, palette.line.copy(alpha = 0.8f), RoundedCornerShape(12.dp))
                .padding(start = 10.dp, end = 4.dp),
        ) {
            Icon(Icons.Filled.Description, contentDescription = null, tint = palette.muted, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(
                text = item.name,
                style = MoMoType.metadata,
                color = palette.ink,
                maxLines = 1,
                modifier = Modifier.width(140.dp),
            )
            IconButton(onClick = onRemove, modifier = Modifier.size(28.dp)) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = stringResource(R.string.chat_remove_attachment),
                    tint = palette.muted,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

private fun decodePreview(value: String?): Bitmap? {
    val bytes = value?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() } ?: return null
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
}
