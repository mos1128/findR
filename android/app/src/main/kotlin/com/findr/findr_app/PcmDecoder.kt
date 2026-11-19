package com.findr.findr_app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.ByteArrayOutputStream

/// 把一段录音解成裸 PCM16（小端、按声道交织）。
///
/// 为什么非得在这边做：本机转写模型要的是 16 kHz 单声道浮点，而库里存的是 AAC
/// （`.m4a`，44.1 kHz），Dart 侧没有 AAC 解码器，只能用系统的 MediaCodec。
/// 这一层只负责「解出来」—— 下混与重采样在 Dart（那边能写单测，这里不能）。
///
/// 返回 `pcm` / `sampleRate` / `channels`；文件里没有音频轨时返回 null。
object PcmDecoder {
    fun decode(path: String): Map<String, Any>? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull { i ->
                extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val out = ByteArrayOutputStream(1 shl 16)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)
                        val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex >= 0) {
                    val buffer = codec.getOutputBuffer(outIndex)
                    if (buffer != null && info.size > 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val chunk = ByteArray(info.size)
                        buffer.get(chunk)
                        out.write(chunk)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            return mapOf(
                "pcm" to out.toByteArray(),
                "sampleRate" to sampleRate,
                "channels" to channels,
            )
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
                // 没 start 成功就 stop 会抛，忽略
            }
            try {
                codec?.release()
            } catch (_: Exception) {
                // 同上
            }
            extractor.release()
        }
    }
}
