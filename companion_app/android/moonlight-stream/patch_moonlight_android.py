#!/usr/bin/env python3
"""Apply GBear companion patches to synced moonlight-android sources."""

from __future__ import annotations

import sys
from pathlib import Path


def patch_file(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"{label}: expected snippet missing in {path}")
    path.write_text(text.replace(old, new, 1))


def patch_game_java(java_root: Path) -> None:
    path = java_root / "com/limelight/Game.java"
    patch_file(
        path,
        "import com.limelight.utils.UiHelper;\n",
        "import com.limelight.utils.UiHelper;\n"
        "import com.gbear.companion.input.GBearControllerMapping;\n",
        "Game import GBearControllerMapping",
    )
    patch_file(
        path,
        "        prefConfig = PreferenceConfiguration.readPreferences(this);\n",
        "        prefConfig = PreferenceConfiguration.readPreferences(this);\n"
        "        GBearControllerMapping.configure(getIntent());\n",
        "Game configure mapping",
    )
    patch_file(
        path,
        "                connected = true;\n"
        "                connecting = false;\n",
        "                connected = true;\n"
        "                connecting = false;\n"
        "                if (GBearControllerMapping.shouldAutoEnableMouseEmulation()) {\n"
        "                    controllerHandler.enableGBearAutoMouseEmulation();\n"
        "                }\n",
        "Game auto mouse emulation",
    )


def patch_controller_handler(java_root: Path) -> None:
    path = java_root / "com/limelight/binding/input/ControllerHandler.java"
    patch_file(
        path,
        "import com.limelight.preferences.PreferenceConfiguration;\n",
        "import com.limelight.preferences.PreferenceConfiguration;\n"
        "import com.gbear.companion.input.GBearControllerMapping;\n",
        "ControllerHandler import GBearControllerMapping",
    )
    patch_file(
        path,
        "        if (prefConfig.flipFaceButtons) {\n"
        "            keyCode = handleFlipFaceButtons(keyCode);\n"
        "        }\n\n"
        "        switch (keyCode) {\n"
        "        case KeyEvent.KEYCODE_BUTTON_MODE:\n"
        "            context.hasMode = true;\n",
        "        if (prefConfig.flipFaceButtons) {\n"
        "            keyCode = handleFlipFaceButtons(keyCode);\n"
        "        }\n\n"
        "        if (GBearControllerMapping.trySendKeyboardForKeyCode(conn, keyCode, true)) {\n"
        "            return true;\n"
        "        }\n\n"
        "        switch (keyCode) {\n"
        "        case KeyEvent.KEYCODE_BUTTON_MODE:\n"
        "            context.hasMode = true;\n",
        "ControllerHandler button down mapping",
    )
    patch_file(
        path,
        "        if (prefConfig.flipFaceButtons) {\n"
        "            keyCode = handleFlipFaceButtons(keyCode);\n"
        "        }\n\n"
        "        // If the button hasn't been down long enough, sleep for a bit before sending the up event\n",
        "        if (prefConfig.flipFaceButtons) {\n"
        "            keyCode = handleFlipFaceButtons(keyCode);\n"
        "        }\n\n"
        "        if (GBearControllerMapping.trySendKeyboardForKeyCode(conn, keyCode, false)) {\n"
        "            return true;\n"
        "        }\n\n"
        "        // If the button hasn't been down long enough, sleep for a bit before sending the up event\n",
        "ControllerHandler button up mapping",
    )
    patch_file(
        path,
        "                // Send mouse events from analog sticks\n"
        "                if (prefConfig.analogStickForScrolling == PreferenceConfiguration.AnalogStickForScrolling.RIGHT) {\n",
        "                // Send mouse events from analog sticks\n"
        "                if (GBearControllerMapping.isAutoMouseEmulation()) {\n"
        "                    sendEmulatedMouseMove(leftStickX, leftStickY);\n"
        "                }\n"
        "                else if (prefConfig.analogStickForScrolling == PreferenceConfiguration.AnalogStickForScrolling.RIGHT) {\n",
        "ControllerHandler left stick mouse",
    )
    patch_file(
        path,
        "            context.leftTrigger = (byte)(lt * 0xFF);\n"
        "            context.rightTrigger = (byte)(rt * 0xFF);\n"
        "        }\n\n"
        "        if (context.hatXAxis != -1 && context.hatYAxis != -1) {\n",
        "            context.leftTrigger = (byte)(lt * 0xFF);\n"
        "            context.rightTrigger = (byte)(rt * 0xFF);\n"
        "            GBearControllerMapping.trySendKeyboardForTrigger(conn, \"leftTrigger\", lt);\n"
        "            GBearControllerMapping.trySendKeyboardForTrigger(conn, \"rightTrigger\", rt);\n"
        "            if (GBearControllerMapping.isMapped(\"leftTrigger\")) {\n"
        "                context.leftTrigger = 0;\n"
        "            }\n"
        "            if (GBearControllerMapping.isMapped(\"rightTrigger\")) {\n"
        "                context.rightTrigger = 0;\n"
        "            }\n"
        "        }\n\n"
        "        if (context.hatXAxis != -1 && context.hatYAxis != -1) {\n",
        "ControllerHandler trigger mapping",
    )
    patch_file(
        path,
        "            context.inputMap &= ~(ControllerPacket.UP_FLAG | ControllerPacket.DOWN_FLAG);\n"
        "            if (hatY < -0.5) {\n"
        "                context.inputMap |= ControllerPacket.UP_FLAG;\n",
        "            context.inputMap &= ~(ControllerPacket.UP_FLAG | ControllerPacket.DOWN_FLAG);\n"
        "            if (hatY < -0.5 && !GBearControllerMapping.isMapped(\"dpadUp\")) {\n"
        "                context.inputMap |= ControllerPacket.UP_FLAG;\n",
        "ControllerHandler dpad up mapping",
    )
    patch_file(
        path,
        "            else if (hatY > 0.5) {\n"
        "                context.inputMap |= ControllerPacket.DOWN_FLAG;\n",
        "            else if (hatY > 0.5 && !GBearControllerMapping.isMapped(\"dpadDown\")) {\n"
        "                context.inputMap |= ControllerPacket.DOWN_FLAG;\n",
        "ControllerHandler dpad down mapping",
    )
    patch_file(
        path,
        "            context.inputMap &= ~(ControllerPacket.LEFT_FLAG | ControllerPacket.RIGHT_FLAG);\n"
        "            if (hatX < -0.5) {\n"
        "                context.inputMap |= ControllerPacket.LEFT_FLAG;\n",
        "            context.inputMap &= ~(ControllerPacket.LEFT_FLAG | ControllerPacket.RIGHT_FLAG);\n"
        "            if (hatX < -0.5 && !GBearControllerMapping.isMapped(\"dpadLeft\")) {\n"
        "                context.inputMap |= ControllerPacket.LEFT_FLAG;\n",
        "ControllerHandler dpad left mapping",
    )
    patch_file(
        path,
        "            else if (hatX > 0.5) {\n"
        "                context.inputMap |= ControllerPacket.RIGHT_FLAG;\n",
        "            else if (hatX > 0.5 && !GBearControllerMapping.isMapped(\"dpadRight\")) {\n"
        "                context.inputMap |= ControllerPacket.RIGHT_FLAG;\n",
        "ControllerHandler dpad right mapping",
    )
    patch_file(
        path,
        "    @Override\n"
        "    public void reportControllerState(int controllerId, int buttonFlags,\n",
        "    public void enableGBearAutoMouseEmulation() {\n"
        "        if (!prefConfig.mouseEmulation || !GBearControllerMapping.shouldAutoEnableMouseEmulation()) {\n"
        "            return;\n"
        "        }\n"
        "        enableGBearMouseEmulationForContext(defaultContext);\n"
        "        for (int i = 0; i < inputDeviceContexts.size(); i++) {\n"
        "            enableGBearMouseEmulationForContext(inputDeviceContexts.valueAt(i));\n"
        "        }\n"
        "        for (int i = 0; i < usbDeviceContexts.size(); i++) {\n"
        "            enableGBearMouseEmulationForContext(usbDeviceContexts.valueAt(i));\n"
        "        }\n"
        "    }\n\n"
        "    private void enableGBearMouseEmulationForContext(GenericControllerContext context) {\n"
        "        if (context == null || context.mouseEmulationActive) {\n"
        "            return;\n"
        "        }\n"
        "        context.mouseEmulationActive = true;\n"
        "        mainThreadHandler.postDelayed(context.mouseEmulationRunnable, context.mouseEmulationReportPeriod);\n"
        "    }\n\n"
        "    @Override\n"
        "    public void reportControllerState(int controllerId, int buttonFlags,\n",
        "ControllerHandler enable auto mouse",
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} <moonlight-java-root>")
    java_root = Path(sys.argv[1])
    patch_game_java(java_root)
    patch_controller_handler(java_root)
    print(f"Patched Moonlight Android sources in {java_root}")


if __name__ == "__main__":
    main()
