package com.example.companion_app

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** Shortcut picker overlay on the live stream; sends chords to the Mac via [GBearKeyboardSender]. */
class GBearStreamShortcutsOverlay(
    private val activity: Activity,
) {
    private var dialog: AlertDialog? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    val isShowing: Boolean
        get() = dialog?.isShowing == true

    fun show() {
        if (isShowing) return
        val shortcuts = GBearStreamShortcutsPrefs.load(activity)
        val scroll = ScrollView(activity).apply {
            setBackgroundColor(Color.parseColor("#E6000000"))
        }
        val list = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 24)
        }
        list.addView(
            TextView(activity).apply {
                text = "Shortcuts"
                setTextColor(Color.WHITE)
                textSize = 20f
                setPadding(0, 0, 0, 8)
            },
        )
        list.addView(
            TextView(activity).apply {
                text = "Tap a shortcut to send it to your Mac."
                setTextColor(Color.parseColor("#B3FFFFFF"))
                textSize = 13f
                setPadding(0, 0, 0, 20)
            },
        )
        for (shortcut in shortcuts) {
            val row = TextView(activity).apply {
                text = "${shortcut.name}\n${shortcut.keyLabel}"
                setTextColor(Color.WHITE)
                textSize = 16f
                setPadding(0, 20, 0, 20)
                setOnClickListener {
                    fireShortcut(shortcut)
                    Toast.makeText(activity, shortcut.name, Toast.LENGTH_SHORT).show()
                }
            }
            list.addView(row)
        }
        scroll.addView(list)
        dialog = AlertDialog.Builder(activity, android.R.style.Theme_DeviceDefault_Dialog_NoActionBar)
            .setView(scroll)
            .setNegativeButton("Close") { d, _ -> d.dismiss() }
            .create()
        GBearOverlayUi.applyDialogWindow(dialog)
        dialog?.window?.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (activity.resources.displayMetrics.heightPixels * 0.75f).toInt(),
        )
        dialog?.window?.setGravity(Gravity.CENTER)
        dialog?.show()
    }

    fun dismiss() {
        dialog?.dismiss()
        dialog = null
    }

    private fun fireShortcut(shortcut: GBearStreamShortcutsPrefs.Shortcut) {
        val keyboard = GBearStreamSession.keyboardSender()
        if (keyboard == null) {
            Toast.makeText(activity, "Stream keyboard unavailable", Toast.LENGTH_SHORT).show()
            GBearStreamLog.w("Shortcut \"${shortcut.name}\" skipped — no keyboard sender")
            return
        }
        val codes = shortcut.moonlightKeyCodes
        if (codes.isEmpty()) return
        GBearStreamLog.i(
            "Shortcut \"${shortcut.name}\" (${shortcut.keyLabel}) → ${GBearStreamSession.host}:${GBearStreamSession.inputPort}",
        )
        keyboard.sendChord(codes, down = true)
        mainHandler.postDelayed({
            keyboard.sendChord(codes, down = false)
        }, CHORD_HOLD_MS)
    }

    companion object {
        private const val CHORD_HOLD_MS = 140L
    }
}
