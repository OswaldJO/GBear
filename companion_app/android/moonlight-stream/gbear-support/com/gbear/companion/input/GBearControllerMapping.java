package com.gbear.companion.input;

import android.content.Intent;
import android.util.Log;
import android.view.KeyEvent;

import com.limelight.nvstream.NvConnection;
import com.limelight.nvstream.input.KeyboardPacket;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.Map;

/**
 * Companion-app controller → keyboard mappings applied during Moonlight streaming.
 */
public final class GBearControllerMapping {
    private static final String TAG = "GBearControllerMap";

    public static final String EXTRA_BINDINGS_JSON = "GBearControllerBindingsJson";
    public static final String EXTRA_AUTO_MOUSE_EMULATION = "GBearAutoMouseEmulation";

    private static final Map<String, short[]> bindingsByElement = new HashMap<>();
    private static final Map<String, Boolean> triggerDownState = new HashMap<>();
    private static boolean autoMouseEmulation;

    private GBearControllerMapping() {}

    public static void configure(Intent intent) {
        bindingsByElement.clear();
        triggerDownState.clear();
        autoMouseEmulation = false;
        if (intent == null) {
            return;
        }

        autoMouseEmulation = intent.getBooleanExtra(EXTRA_AUTO_MOUSE_EMULATION, false);
        String json = intent.getStringExtra(EXTRA_BINDINGS_JSON);
        if (json == null || json.isEmpty()) {
            return;
        }

        try {
            JSONArray array = new JSONArray(json);
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.getJSONObject(i);
                String elementId = item.optString("sourceElementId", "");
                short[] codes = parseKeyCodes(item);
                if (!elementId.isEmpty() && codes.length > 0) {
                    bindingsByElement.put(elementId, codes);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed to parse controller bindings JSON", e);
        }
    }

    public static boolean hasBindings() {
        return !bindingsByElement.isEmpty();
    }

    public static boolean shouldAutoEnableMouseEmulation() {
        return autoMouseEmulation;
    }

    public static boolean isAutoMouseEmulation() {
        return autoMouseEmulation;
    }

    private static short[] parseKeyCodes(JSONObject item) {
        if (item.has("moonlightKeyCodes")) {
            JSONArray arr = item.optJSONArray("moonlightKeyCodes");
            if (arr == null) {
                return new short[0];
            }
            short[] out = new short[arr.length()];
            int count = 0;
            for (int i = 0; i < arr.length(); i++) {
                int code = arr.optInt(i, 0);
                if (code != 0) {
                    out[count++] = (short) code;
                }
            }
            if (count == out.length) {
                return out;
            }
            short[] trimmed = new short[count];
            System.arraycopy(out, 0, trimmed, 0, count);
            return trimmed;
        }
        int single = item.optInt("moonlightKeyCode", 0);
        if (single == 0) {
            return new short[0];
        }
        return new short[] {(short) single};
    }

    public static boolean isMapped(String elementId) {
        short[] mapped = bindingsByElement.get(elementId);
        return mapped != null && mapped.length > 0;
    }

    public static void trySendKeyboardForTrigger(NvConnection conn, String elementId, float axisValue) {
        if (conn == null || !isMapped(elementId)) {
            return;
        }

        boolean down = axisValue > 0.65f;
        Boolean previous = triggerDownState.get(elementId);
        if (previous != null && previous == down) {
            return;
        }
        triggerDownState.put(elementId, down);

        short[] mapped = bindingsByElement.get(elementId);
        if (mapped == null) {
            return;
        }
        sendChord(conn, mapped, down);
    }

    private static void sendChord(NvConnection conn, short[] codes, boolean down) {
        if (codes == null || codes.length == 0) {
            return;
        }
        int start = down ? 0 : codes.length - 1;
        int end = down ? codes.length : -1;
        int step = down ? 1 : -1;
        for (int i = start; i != end; i += step) {
            conn.sendKeyboardInput(
                    codes[i],
                    down ? KeyboardPacket.KEY_DOWN : KeyboardPacket.KEY_UP,
                    (byte) 0,
                    (byte) 0);
        }
    }

    public static boolean trySendKeyboardForKeyCode(NvConnection conn, int keyCode, boolean down) {
        if (conn == null || bindingsByElement.isEmpty()) {
            return false;
        }

        String elementId = elementIdForKeyCode(keyCode);
        if (elementId == null) {
            return false;
        }

        short[] mapped = bindingsByElement.get(elementId);
        if (mapped == null || mapped.length == 0) {
            return false;
        }

        sendChord(conn, mapped, down);
        return true;
    }

    private static String elementIdForKeyCode(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_BUTTON_A:
            case KeyEvent.KEYCODE_DPAD_CENTER:
                return "buttonA";
            case KeyEvent.KEYCODE_BUTTON_B:
                return "buttonB";
            case KeyEvent.KEYCODE_BUTTON_X:
                return "buttonX";
            case KeyEvent.KEYCODE_BUTTON_Y:
                return "buttonY";
            case KeyEvent.KEYCODE_BUTTON_L1:
                return "leftShoulder";
            case KeyEvent.KEYCODE_BUTTON_R1:
                return "rightShoulder";
            case KeyEvent.KEYCODE_BUTTON_L2:
                return "leftTrigger";
            case KeyEvent.KEYCODE_BUTTON_R2:
                return "rightTrigger";
            case KeyEvent.KEYCODE_BUTTON_THUMBL:
                return "leftThumbstickButton";
            case KeyEvent.KEYCODE_BUTTON_THUMBR:
                return "rightThumbstickButton";
            case KeyEvent.KEYCODE_DPAD_UP:
                return "dpadUp";
            case KeyEvent.KEYCODE_DPAD_DOWN:
                return "dpadDown";
            case KeyEvent.KEYCODE_DPAD_LEFT:
                return "dpadLeft";
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                return "dpadRight";
            case KeyEvent.KEYCODE_BUTTON_START:
            case KeyEvent.KEYCODE_MENU:
                return "buttonMenu";
            case KeyEvent.KEYCODE_BUTTON_SELECT:
            case KeyEvent.KEYCODE_BACK:
                return "buttonOptions";
            case KeyEvent.KEYCODE_BUTTON_1:
                return "macro1";
            case KeyEvent.KEYCODE_BUTTON_2:
                return "macro2";
            case KeyEvent.KEYCODE_BUTTON_3:
                return "macro3";
            case KeyEvent.KEYCODE_BUTTON_4:
                return "macro4";
            default:
                return null;
        }
    }
}
