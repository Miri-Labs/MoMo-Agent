package com.momoagent.android.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt

/** An invisible layout slot that a live avatar can move into. */
data class AvatarPlaceholder(val position: Offset, val size: Dp)

data class AvatarPlacement(val offset: IntOffset, val size: Dp, val layoutHeight: Dp)

fun AvatarPlaceholder.target(parent: Offset?, layoutHeight: Dp): AvatarPlacement? {
    val origin = parent ?: return null
    return AvatarPlacement(
        offset = IntOffset(
            (position.x - origin.x).roundToInt(),
            (position.y - origin.y).roundToInt(),
        ),
        size = size,
        layoutHeight = layoutHeight,
    )
}
