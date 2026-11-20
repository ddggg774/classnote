// test/audio_capture_profile_test.dart
// 远场拾音档位测试。
//
// 这块没什么复杂逻辑，但有两个地方容易悄悄写错：
//   ① 档位到 RecordConfig 的映射错了，等于设置页白给（用户选了"大教室"，
//      实际没开回声消除）
//   ② 采样率改了会直接导致 ASR 拒绝或识别质量下降
// 所以逐项断言，不靠"看起来对"。
import 'package:flutter_test/flutter_test.dart';
import 'package:classnote/services/audio_capture_profile.dart';

void main() {
  group('档位与音频效果的对应关系', () {
    test('安静教室：只开自动增益，不开降噪（避免削弱语音细节）', () {
      const p = CaptureProfile.quiet;
      expect(p.autoGain, isTrue);
      expect(p.noiseSuppress, isFalse);
      expect(p.echoCancel, isFalse);
    });

    test('普通教室：降噪 + 自动增益，不开回声消除', () {
      const p = CaptureProfile.normal;
      expect(p.autoGain, isTrue);
      expect(p.noiseSuppress, isTrue);
      expect(p.echoCancel, isFalse);
    });

    test('大教室/后排：三项全开', () {
      const p = CaptureProfile.far;
      expect(p.autoGain, isTrue);
      expect(p.noiseSuppress, isTrue);
      expect(p.echoCancel, isTrue);
    });

    test('每档都至少开了一项处理', () {
      for (final p in CaptureProfile.values) {
        expect(p.hasProcessing, isTrue, reason: '${p.label} 什么都没开');
      }
    });
  });

  group('映射到 RecordConfig', () {
    test('效果开关被正确传下去', () {
      for (final p in CaptureProfile.values) {
        final cfg = p.toRecordConfig();
        expect(cfg.autoGain, p.autoGain,
            reason: '${p.label} 的自动增益没传对');
        expect(cfg.noiseSuppress, p.noiseSuppress,
            reason: '${p.label} 的降噪没传对');
        expect(cfg.echoCancel, p.echoCancel,
            reason: '${p.label} 的回声消除没传对');
      }
    });

    test('采样率固定 16k 单声道（ASR 要的格式）', () {
      final cfg = CaptureProfile.normal.toRecordConfig();
      expect(cfg.sampleRate, 16000);
      expect(cfg.numChannels, 1);
      expect(CaptureProfile.sampleRate, 16000);
    });
  });

  group('从存储值解析', () {
    test('三个档位 code 都能还原', () {
      expect(CaptureProfile.fromCode('quiet'), CaptureProfile.quiet);
      expect(CaptureProfile.fromCode('normal'), CaptureProfile.normal);
      expect(CaptureProfile.fromCode('far'), CaptureProfile.far);
    });

    test('未知值与 null 退回普通教室（最稳妥的默认）', () {
      expect(CaptureProfile.fromCode('乱写'), CaptureProfile.normal);
      expect(CaptureProfile.fromCode(null), CaptureProfile.normal);
      expect(CaptureProfile.fromCode(''), CaptureProfile.normal);
    });

    test('name 与 fromCode 往返一致（设置页存的就是 name）', () {
      for (final p in CaptureProfile.values) {
        expect(CaptureProfile.fromCode(p.name), p);
      }
    });
  });

  group('界面显示文案', () {
    test('activeEffects 列出开启项', () {
      expect(CaptureProfile.quiet.activeEffects, '自动增益');
      expect(CaptureProfile.normal.activeEffects, '自动增益 + 降噪');
      expect(CaptureProfile.far.activeEffects, '自动增益 + 降噪 + 回声消除');
    });

    test('每档都有标签与说明', () {
      for (final p in CaptureProfile.values) {
        expect(p.label.trim(), isNotEmpty);
        expect(p.description.trim(), isNotEmpty);
      }
    });
  });
}