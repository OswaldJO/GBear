package com.example.companion_app

import java.nio.ByteBuffer
import java.nio.ByteOrder

object PlayniteStreamProtocols {
    const val VIDEO_MAGIC = 0x31564E50 // PNV1
    const val AUDIO_MAGIC = 0x31414E50 // PNA1
    const val AUDIO_SUBSCRIBE_MAGIC = 0x53414E50 // PNAS
    const val INPUT_MAGIC = 0x31494E50 // PNI1
    const val KEYBOARD_MAGIC = 0x314B4E50 // PNK1
    const val GAMEPAD_MAGIC = 0x31474E50 // PNG1

    const val VIDEO_HEADER_SIZE = 13
    const val AUDIO_HEADER_SIZE = 11
    const val INPUT_PACKET_SIZE = 13
    const val KEYBOARD_PACKET_SIZE = 8
    const val GAMEPAD_PACKET_SIZE = 33

    fun buildInputPacket(
        type: Int,
        button: Int,
        xNorm: Int,
        yNorm: Int,
        scrollDelta: Short = 0,
    ): ByteArray {
        val buf = ByteBuffer.allocate(INPUT_PACKET_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(INPUT_MAGIC)
        buf.put(type.toByte())
        buf.put(button.toByte())
        buf.putShort(xNorm.toShort())
        buf.putShort(yNorm.toShort())
        buf.putShort(scrollDelta)
        return buf.array()
    }

    fun audioSubscribePacket(): ByteArray {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(AUDIO_SUBSCRIBE_MAGIC)
            .array()
    }

    fun buildKeyboardPacket(moonlightKeyCode: Int, down: Boolean): ByteArray {
        val buf = ByteBuffer.allocate(KEYBOARD_PACKET_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(KEYBOARD_MAGIC)
        buf.put(if (down) 1.toByte() else 0.toByte())
        buf.put(0)
        buf.putShort(moonlightKeyCode.toShort())
        return buf.array()
    }

    fun buildGamepadPacket(
        seat: Int,
        buttons: Int,
        leftX: Float,
        leftY: Float,
        rightX: Float,
        rightY: Float,
        leftTrigger: Float,
        rightTrigger: Float,
    ): ByteArray {
        val buf = ByteBuffer.allocate(GAMEPAD_PACKET_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(GAMEPAD_MAGIC)
        buf.put(seat.coerceIn(1, 8).toByte())
        buf.putInt(buttons)
        buf.putFloat(leftX)
        buf.putFloat(leftY)
        buf.putFloat(rightX)
        buf.putFloat(rightY)
        buf.putFloat(leftTrigger)
        buf.putFloat(rightTrigger)
        return buf.array()
    }

    object GamepadButtons {
        const val A = 1 shl 0
        const val B = 1 shl 1
        const val X = 1 shl 2
        const val Y = 1 shl 3
        const val L1 = 1 shl 4
        const val R1 = 1 shl 5
        const val L3 = 1 shl 6
        const val R3 = 1 shl 7
        const val START = 1 shl 8
        const val SELECT = 1 shl 9
        const val DPAD_UP = 1 shl 10
        const val DPAD_DOWN = 1 shl 11
        const val DPAD_LEFT = 1 shl 12
        const val DPAD_RIGHT = 1 shl 13
        const val GUIDE = 1 shl 14
    }
}
