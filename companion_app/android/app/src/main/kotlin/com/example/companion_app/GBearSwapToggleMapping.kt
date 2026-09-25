package com.example.companion_app

/** Which logical gamepad elements may be assigned to toggle Swap mouse mode. */
object GBearSwapToggleMapping {
    const val TARGET_ACTION_TOGGLE_SWAP = "toggleSwap"
    const val TARGET_LABEL = "Swap mode (toggle)"

    private val excludedElementIds = setOf(
        "buttonA",
        "buttonB",
        "buttonX",
    )

    fun canMapSwapToggleTo(elementId: String): Boolean = elementId !in excludedElementIds
}
