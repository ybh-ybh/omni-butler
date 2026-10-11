import 'dart:io';
import 'dart:typed_data';

/// 创建、修复本模块固定格式 WAV，强退后按磁盘真实字节数重建长度。
abstract final class NoteWav {
  /// 采样率，腾讯录音文件识别可直接接收该原件。
  static const int sampleRate = 16000;

  /// 单声道 16 bit PCM 每秒字节数。
  static const int bytesPerSecond = sampleRate * 2;

  /// 标准 PCM WAV 头长度。
  static const int headerSize = 44;

  /// 生成小端 WAV 文件头。
  static Uint8List header(int audioBytes) {
    // 固定 PCM 文件头缓冲。
    final data = ByteData(headerSize);
    // 写入 ASCII 区块名。
    void text(int offset, String value) {
      // 当前字符位置。
      for (var index = 0; index < value.length; index++) {
        data.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    text(0, 'RIFF');
    data.setUint32(4, audioBytes + 36, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, bytesPerSecond, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    text(36, 'data');
    data.setUint32(40, audioBytes, Endian.little);
    return data.buffer.asUint8List();
  }

  /// 修复持久化原音，不把未采集的暂停时间计入时长。
  static Future<Duration?> repair(File file) async {
    if (!await file.exists()) return null;
    // 以随机写入打开原件，不截断现有音频。
    final handle = await file.open(mode: FileMode.append);
    try {
      // 实际可恢复的完整采样字节数。
      final bytes = ((await handle.length()) - headerSize) ~/ 2 * 2;
      if (bytes <= 0) return null;
      await handle.truncate(bytes + headerSize);
      await handle.setPosition(0);
      await handle.writeFrom(header(bytes));
      await handle.flush();
      return Duration(microseconds: bytes * 1000000 ~/ bytesPerSecond);
    } finally {
      await handle.close();
    }
  }
}
