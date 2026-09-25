package com.example.companion_app

import android.app.Activity
import android.app.AlertDialog
import android.graphics.drawable.ColorDrawable
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Spinner
import android.widget.TextView
import com.example.companion_app.R

/** Shared dark styling for stream overlay dialogs (mapping, shortcuts). */
object GBearOverlayUi {
    const val PANEL_BG = 0xE6000000.toInt()
    const val CARD_BG = 0x33000000
    const val SPINNER_BG = 0xFF2D2D2D.toInt()
    const val POPUP_BG = 0xFF1E1E1E.toInt()
    const val TEXT_PRIMARY = 0xFFFFFFFF.toInt()
    const val TEXT_SECONDARY = 0xB3FFFFFF.toInt()
    const val TEXT_MUTED = 0x99FFFFFF.toInt()
    const val ACCENT = 0xFF8AB4FF.toInt()

    fun applyDialogWindow(dialog: AlertDialog?) {
        dialog?.window?.setBackgroundDrawable(ColorDrawable(PANEL_BG))
        dialog?.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(ACCENT)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.setTextColor(ACCENT)
        }
    }

    fun bindKeySpinner(activity: Activity, spinner: Spinner, labels: List<String>) {
        spinner.adapter = object : ArrayAdapter<String>(
            activity,
            R.layout.gbear_spinner_item,
            labels,
        ) {
            override fun getDropDownView(position: Int, convertView: android.view.View?, parent: ViewGroup): android.view.View {
                val view = super.getDropDownView(position, convertView, parent) as TextView
                view.setBackgroundColor(SPINNER_BG)
                view.setTextColor(TEXT_PRIMARY)
                return view
            }
        }
        spinner.setBackgroundColor(SPINNER_BG)
        spinner.setPopupBackgroundDrawable(ColorDrawable(POPUP_BG))
    }
}
