// lib/services/audio_capture_profile.dart
// 远场拾音配置：降噪 / 自动增益 / 回声消除。
//
// 【为什么用系统音频效果而不是打包一个降噪模型】
// 我先真去试了 RNNoise 的 Flutter 封装（flutter_nnnoiseless）。
// 它在这个构建环境里跑不起来，三个硬障碍：
//   ① 它的 cargokit 脚本用 Gradle 早已废弃的 Project.exec()，
//      本项目 Gradle 9.5 直接报 "Could not find method exec()"；
//   ② 要求 NDK 29（机器上只有 28.2）；
//   ③ 包内没带预编译 .so，需要本地交叉编译 Rust，
//      而机器上根本没有 Rust 工具链。
// 硬闯要装 Rust + NDK 29 + 改第三方构建脚本，成本高且脆弱。
//
// 而 record 包本身就把 Android 的 AudioEffect 暴露出来了：
//   noiseSuppress → NoiseSuppressor（稳态噪声：风扇、空调、投影仪）
//   autoGain      → AutomaticGainControl（远场最要命的是音量小，这个最关键）
//   echoCancel    → AcousticEchoCanceler（教室空旷混响、喇叭回授）
// 这三项由系统音频框架在录音链路上处理，零依赖、零额外体积、不增加耗电，
// 对"坐后排录课"这个场景是性价比最高的第一步。
//
// 真要上神经网络降噪（RNNoise 这类）得先解决上面三条，那是另一件事，
// 不该混在这次改动里一起冒险。
import 'package:record/record.dart';

/// 拾音档位。不同教室环境适合不同强度。
enum CaptureProfile {
  /// 安静小教室：只做自动增益，避免降噪削掉语音细节
  quiet(
    label: '安静教室',
    description: '只开自动增益。适合小教室、人少、环境安静',
    autoGain: true,
    noiseSuppress: false,
    echoCancel: false,
  ),

  /// 普通教室（默认）：开降噪 + 自动增益
  normal(
    label: '普通教室',
    description: '降噪 + 自动增益。适合大多数课堂，抑制风扇空调声',
    autoGain: true,
    noiseSuppress: true,
    echoCancel: false,
  ),

  /// 大教室 / 坐后排：三项全开
  far(
    label: '大教室/后排',
    description: '降噪 + 自动增益 + 回声消除。适合大阶梯教室、坐后排',
    autoGain: true,
    noiseSuppress: true,
    echoCancel: true,
  );

  const CaptureProfile({
    required this.label,
    required this.description,
    required this.autoGain,
    required this.noiseSuppress,
    required this.echoCancel,
  });

  final String label;
  final String description;
  final bool autoGain;
  final bool noiseSuppress;
  final bool echoCancel;

  /// 是否启用了任何处理
  bool get hasProcessing => autoGain || noiseSuppress || echoCancel;

  static CaptureProfile fromCode(String? code) {
    switch (code) {
      case 'quiet':
        return CaptureProfile.quiet;
      case 'far':
        return CaptureProfile.far;
      case 'normal':
      default:
        return CaptureProfile.normal;
    }
  }

  /// 生成录音配置。
  ///
  /// 采样率固定 16kHz 单声道：ASR 接口吃的就是这个格式，
  /// 自己先降采样能减少上传体积，也让降噪处理更快。
  RecordConfig toRecordConfig() => RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: autoGain,
        noiseSuppress: noiseSuppress,
        echoCancel: echoCancel,
      );

  /// ASR 需要的采样率
  static const int sampleRate = 16000;

  /// 给界面显示的开启项（一眼看出现在开了什么）
  String get activeEffects {
    final items = <String>[];
    if (autoGain) items.add('自动增益');
    if (noiseSuppress) items.add('降噪');
    if (echoCancel) items.add('回声消除');
    return items.isEmpty ? '无' : items.join(' + ');
  }
}