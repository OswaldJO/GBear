package com.example.companion_app

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast

/**
 * Stream overlay for per-button keyboard chords and optional manual gamepad linking.
 */
class GBearControllerMappingOverlay(
    private val activity: Activity,
    private val onBindingsJsonChanged: (String) -> Unit,
) {
    data class MappableElement(val id: String, val label: String)

    private var dialog: AlertDialog? = null
    private var selectedElementId: String? = null
    private val selectedKeyCodes = mutableListOf<Int>()
    private var detailPanel: LinearLayout? = null
    private var listContainer: LinearLayout? = null
    private var chordChipsRow: LinearLayout? = null

    val isShowing: Boolean
        get() = dialog?.isShowing == true

    fun show() {
        if (isShowing) return
        if (selectedElementId == null) {
            selectedElementId = mappableElements().firstOrNull()?.id
        }
        loadSelectedKeysFromPrefs()
        rebuildDialog()
    }

    fun dismiss() {
        GamepadLinkCapture.cancel()
        dialog?.dismiss()
        dialog = null
        detailPanel = null
        listContainer = null
        chordChipsRow = null
    }

    private fun loadSelectedKeysFromPrefs() {
        selectedKeyCodes.clear()
        val id = selectedElementId ?: return
        selectedKeyCodes.addAll(GBearStreamMappingPrefs.moonlightKeyCodesForElement(activity, id))
    }

    private fun rebuildDialog() {
        val elements = mappableElements()
        val scroll = ScrollView(activity).apply {
            setBackgroundColor(GBearOverlayUi.PANEL_BG)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 24)
        }
        root.addView(
            TextView(activity).apply {
                text = "Controller mapping"
                setTextColor(GBearOverlayUi.TEXT_PRIMARY)
                textSize = 20f
                setPadding(0, 0, 0, 8)
            },
        )
        root.addView(
            TextView(activity).apply {
                text = "Tap a button below, then assign keyboard keys or link your gamepad."
                setTextColor(GBearOverlayUi.TEXT_SECONDARY)
                textSize = 13f
                setPadding(0, 0, 0, 16)
            },
        )

        detailPanel = buildDetailPanel(elements)
        root.addView(detailPanel)

        listContainer = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 16, 0, 0)
        }
        for (element in elements) {
            listContainer?.addView(buildElementRow(element))
        }
        root.addView(listContainer)
        scroll.addView(root)

        dialog?.dismiss()
        dialog = AlertDialog.Builder(activity, android.R.style.Theme_DeviceDefault_Dialog_NoActionBar)
            .setView(scroll)
            .setNegativeButton("Close") { d, _ -> d.dismiss() }
            .create()
        GBearOverlayUi.applyDialogWindow(dialog)
        dialog?.window?.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (activity.resources.displayMetrics.heightPixels * 0.88f).toInt(),
        )
        dialog?.window?.setGravity(Gravity.CENTER)
        dialog?.setOnDismissListener {
            GamepadLinkCapture.cancel()
            dialog = null
        }
        dialog?.show()
    }

    private fun buildDetailPanel(elements: List<MappableElement>): LinearLayout {
        val panel = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 16, 20, 16)
            setBackgroundColor(GBearOverlayUi.CARD_BG)
        }
        val selected = elements.firstOrNull { it.id == selectedElementId }
        if (selected == null) {
            panel.addView(
                TextView(activity).apply {
                    text = "Select a controller button"
                    setTextColor(GBearOverlayUi.TEXT_MUTED)
                    textSize = 14f
                },
            )
            return panel
        }

        panel.addView(
            TextView(activity).apply {
                text = "Editing: ${selected.label}"
                setTextColor(GBearOverlayUi.TEXT_PRIMARY)
                textSize = 17f
                setPadding(0, 0, 0, 8)
            },
        )
        panel.addView(
            TextView(activity).apply {
                text = "Mapped to: ${GBearStreamMappingPrefs.targetLabelForElement(activity, selected.id)}"
                setTextColor(GBearOverlayUi.TEXT_MUTED)
                textSize = 13f
                setPadding(0, 0, 0, 12)
            },
        )

        chordChipsRow = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
        }
        refreshChordChips(selected)
        panel.addView(chordChipsRow)

        val addRow = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 12, 0, 8)
        }
        val spinner = Spinner(activity)
        val labels = MoonlightKeyboardKeys.common.map { it.label }
        GBearOverlayUi.bindKeySpinner(activity, spinner, labels)
        addRow.addView(
            spinner,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        addRow.addView(
            TextView(activity).apply {
                text = "Add key"
                setTextColor(GBearOverlayUi.ACCENT)
                textSize = 14f
                setPadding(24, 16, 0, 16)
                setOnClickListener {
                    val pick = MoonlightKeyboardKeys.common.getOrNull(spinner.selectedItemPosition) ?: return@setOnClickListener
                    if (pick.moonlightKeyCode in selectedKeyCodes) {
                        Toast.makeText(activity, "${pick.label} already in chord", Toast.LENGTH_SHORT).show()
                        return@setOnClickListener
                    }
                    selectedKeyCodes.add(pick.moonlightKeyCode)
                    refreshChordChips(selected)
                }
            },
        )
        panel.addView(addRow)

        val actions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 8, 0, 0)
        }
        actions.addView(actionButton("Save keys") { saveKeyboardChord(selected) })
        actions.addView(actionButton("Clear") { clearMapping(selected) })
        panel.addView(actions)

        if (GBearSwapToggleMapping.canMapSwapToggleTo(selected.id)) {
            panel.addView(
                TextView(activity).apply {
                    text = "Assign Swap mode (toggle)"
                    setTextColor(GBearOverlayUi.ACCENT)
                    textSize = 14f
                    setPadding(0, 16, 0, 0)
                    setOnClickListener { assignSwapToggle(selected) }
                },
            )
        }

        panel.addView(
            TextView(activity).apply {
                text = "Link physical gamepad button"
                setTextColor(GBearOverlayUi.ACCENT)
                textSize = 14f
                setPadding(0, 16, 0, 0)
                setOnClickListener { startLink(selected) }
            },
        )
        return panel
    }

    private fun refreshChordChips(selected: MappableElement) {
        val row = chordChipsRow ?: return
        row.removeAllViews()
        if (selectedKeyCodes.isEmpty()) {
            row.addView(
                TextView(activity).apply {
                    text = "No keys in chord — add keys above"
                    setTextColor(GBearOverlayUi.TEXT_MUTED)
                    textSize = 13f
                },
            )
            return
        }
        val chips = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        for (code in selectedKeyCodes.toList()) {
            chips.addView(
                TextView(activity).apply {
                    text = "${MoonlightKeyboardKeys.labelForCode(code)}  ✕"
                    setTextColor(GBearOverlayUi.TEXT_PRIMARY)
                    textSize = 13f
                    setPadding(16, 8, 16, 8)
                    setBackgroundColor(Color.parseColor("#44FFFFFF"))
                    setOnClickListener {
                        selectedKeyCodes.remove(code)
                        refreshChordChips(selected)
                    }
                },
            )
            chips.addView(View(activity), LinearLayout.LayoutParams(8, 1))
        }
        row.addView(chips)
    }

    private fun buildElementRow(element: MappableElement): View {
        val selected = element.id == selectedElementId
        return LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 14, 16, 14)
            setBackgroundColor(if (selected) Color.parseColor("#44FFFFFF") else Color.TRANSPARENT)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                selectedElementId = element.id
                loadSelectedKeysFromPrefs()
                rebuildDialog()
            }
            addView(
                TextView(activity).apply {
                    text = element.label
                    setTextColor(GBearOverlayUi.TEXT_PRIMARY)
                    textSize = 16f
                },
            )
            addView(
                TextView(activity).apply {
                    text = GBearStreamMappingPrefs.targetLabelForElement(activity, element.id)
                    setTextColor(GBearOverlayUi.TEXT_MUTED)
                    textSize = 13f
                    setPadding(0, 4, 0, 0)
                },
            )
        }
    }

    private fun actionButton(label: String, onClick: () -> Unit): TextView =
        TextView(activity).apply {
            text = label
            setTextColor(GBearOverlayUi.ACCENT)
            textSize = 14f
            setPadding(0, 8, 24, 8)
            setOnClickListener { onClick() }
        }

    private fun assignSwapToggle(element: MappableElement) {
        val json = GBearStreamMappingPrefs.upsertSwapToggleMapping(
            activity,
            element.id,
            element.label,
        )
        applyBindings(json)
        selectedKeyCodes.clear()
        Toast.makeText(activity, "${element.label} → ${GBearSwapToggleMapping.TARGET_LABEL}", Toast.LENGTH_SHORT).show()
        rebuildDialog()
    }

    private fun saveKeyboardChord(element: MappableElement) {
        val label = if (selectedKeyCodes.isEmpty()) {
            "Unmapped"
        } else {
            selectedKeyCodes.joinToString(" + ") { MoonlightKeyboardKeys.labelForCode(it) }
        }
        val json = GBearStreamMappingPrefs.upsertKeyboardMapping(
            activity,
            element.id,
            element.label,
            selectedKeyCodes.toList(),
            label,
        )
        applyBindings(json)
        Toast.makeText(activity, "Saved ${element.label} → $label", Toast.LENGTH_SHORT).show()
        rebuildDialog()
    }

    private fun clearMapping(element: MappableElement) {
        selectedKeyCodes.clear()
        val json = GBearStreamMappingPrefs.clearElementMapping(activity, element.id)
        applyBindings(json)
        Toast.makeText(activity, "Cleared ${element.label}", Toast.LENGTH_SHORT).show()
        rebuildDialog()
    }

    private fun applyBindings(json: String) {
        GBearStreamSession.controllerBindingsJson = json
        onBindingsJsonChanged(json)
    }

    private fun startLink(element: MappableElement) {
        Toast.makeText(
            activity,
            "Press a button, D-pad direction, or push a stick for ${element.label}",
            Toast.LENGTH_SHORT,
        ).show()
        if (!GamepadLinkCapture.beginListening(element.id) { captured ->
            activity.runOnUiThread {
                val json = GBearStreamMappingPrefs.upsertPhysicalLink(
                    activity,
                    element.id,
                    element.label,
                    captured.keyCode,
                    captured.label,
                )
                applyBindings(json)
                loadSelectedKeysFromPrefs()
                Toast.makeText(
                    activity,
                    "${element.label} linked to ${captured.label}",
                    Toast.LENGTH_SHORT,
                ).show()
                rebuildDialog()
            }
        }) {
            Toast.makeText(activity, "Already waiting for a button press", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        fun mappableElements(): List<MappableElement> = listOf(
            MappableElement("buttonA", "A / Cross"),
            MappableElement("buttonB", "B / Circle"),
            MappableElement("buttonX", "X / Square"),
            MappableElement("buttonY", "Y / Triangle"),
            MappableElement("leftShoulder", "Left bumper (L1)"),
            MappableElement("rightShoulder", "Right bumper (R1)"),
            MappableElement("leftTrigger", "Left trigger (L2)"),
            MappableElement("rightTrigger", "Right trigger (R2)"),
            MappableElement("leftThumbstickButton", "Left stick click (L3)"),
            MappableElement("leftStickUp", "Left stick up"),
            MappableElement("leftStickDown", "Left stick down"),
            MappableElement("leftStickLeft", "Left stick left"),
            MappableElement("leftStickRight", "Left stick right"),
            MappableElement("rightThumbstickButton", "Right stick click (R3)"),
            MappableElement("rightStickUp", "Right stick up"),
            MappableElement("rightStickDown", "Right stick down"),
            MappableElement("rightStickLeft", "Right stick left"),
            MappableElement("rightStickRight", "Right stick right"),
            MappableElement("dpadUp", "D-pad up"),
            MappableElement("dpadDown", "D-pad down"),
            MappableElement("dpadLeft", "D-pad left"),
            MappableElement("dpadRight", "D-pad right"),
            MappableElement("buttonMenu", "Start / Menu"),
            MappableElement("buttonOptions", "Select / Options"),
            MappableElement("macro1", "Macro 1"),
            MappableElement("macro2", "Macro 2"),
            MappableElement("macro3", "Macro 3"),
            MappableElement("macro4", "Macro 4"),
        )
    }
}
