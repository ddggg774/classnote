// lib/pages/disclaimer_page.dart
// 首次使用前的免责声明与同意页。
//
// 【为什么是「必须同意才能用」】
// 这个 App 会录课堂声音、把录音与文本发给第三方模型。录音涉及老师与同学的
// 权利，AI 输出也可能出错。把这些讲清楚、让用户明确点一次，比藏在设置里
// 一句「仅供学习」更负责。
//
// 【记录什么】
// 只在本机记「同意的版本号 + 时间」，不上传。版本号变了会再次要求确认。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';

/// 免责声明的正文与版本号。
///
/// 修改正文时**必须**同时改 [version]：否则老用户不会再看到新条款。
class Disclaimer {
  /// 与 docs/免责声明.md 保持一致，改一处就要改另一处
  static const String version = '1.1';

  static const String text = '''
课堂笔记（classnote）免责声明与使用协议

版本 1.1　生效日期：2026 年 11 月 23 日

使用本应用前，请完整阅读本声明。你在应用内勾选「我已阅读并同意」并继续使用，即视为你已理解并接受全部条款。如果你不同意任何一条，请不要使用本应用并卸载。

一、本应用是什么

课堂笔记（classnote）是一个开源的个人学习工具，用麦克风录制课堂声音，借助第三方语音识别与大语言模型，生成转写稿、逐句译文、纠错建议与课程总结。

它不是教学服务、不是学习辅导机构、不是考试工具，也不提供任何专业意见。作者是个人开发者，不是学校、教育机构或商业公司。

二、录音合规（请务必先读这一条）

课堂录音涉及他人的声音、肖像、讲课内容与著作权。是否允许录音，取决于你所在学校的规定、授课教师的要求以及在场同学的意愿。

你承诺：

1. 录音前已遵守学校、院系与课堂的管理规定；学校或教师明确禁止录音的，你不得使用本应用录音；
2. 已如实告知授课教师与在场同学，并取得他们的同意（法律或校规另有要求的，从其要求）；
3. 录音仅用于你个人的学习与复习，不公开传播、不上传至公开平台、不用于营利、不用于侮辱、诽谤、恶搞或断章取义；
4. 不将录音或转写内容用于抄袭、代写、考试作弊或任何违反学术诚信的用途；
5. 课堂讲授内容的著作权归授课教师或学校所有；你仅在自己学习所需的范围内使用，不主张任何权利。

因录音行为本身引发的纠纷、投诉、处分或法律责任，由你自行承担，作者不承担任何责任。

三、AI 生成内容的边界

转写、翻译、纠错、总结、思维导图、知识库词条均由第三方模型生成。模型会出错，而且可能以很自信的方式出错：

· 可能听错、漏听、把专业术语写成同音词；
· 翻译可能错译、漏译、把句子合并或改写；
· 总结可能遗漏要点、张冠李戴，甚至生成原文没有的内容（幻觉）；
· 术语释义、考点提示、复习题可能不准确。

因此：

1. 本应用的输出只能作为复习的辅助线索，不能作为事实依据。考试、作业、论文、实验报告中的任何内容，都必须回到教材、讲义与原始录音核对。
2. 不要把它当作医疗、法律、财务、心理等任何专业建议。
3. 涉及成绩、学分、处分、学术不端认定的场景，请以学校与教师的正式要求为准。
4. 应用内已尽量标注「待确认」「转写缺失」等提示，但这些提示本身也不保证完备。

四、第三方服务、费用与数据出境

本应用自身不提供 AI 能力，全部依赖你自行申请密钥的第三方服务：

· 语音转写：硅基流动（SiliconFlow），发送录音片段（按 60 秒切片上传）；
· 纠错 / 总结 / 翻译 / 词条抽取：DeepSeek，发送转写文本、你填写的课程与章节信息、提示词。

密钥由你本人申请并保存在本机，作者不接触、不代收任何费用。调用产生的费用由你自行承担，具体价格以服务商官网为准；作者无法控制服务商的计费方式与调价。

你的录音与文本会离开本机、发送至上述服务商，其处理方式受各自服务条款与隐私政策约束。涉及敏感内容（他人隐私、未公开的研究数据、涉密课程）时，请勿使用本应用。

服务商可能变更接口、限制访问或停止服务，导致功能不可用，作者不承担因此产生的责任。

五、质检的联网检索（维基百科）

学科质检在联网可用时会检索中文维基百科（zh.wikipedia.org，MediaWiki API）。检索只发送待核对的术语或短句，不发送整篇笔记、录音或任何个人信息；返回的公开条目摘要仅用于辅助判断，可能不准确、不完整。

你可以在「设置 → 学科质检时检索维基百科」随时关闭；关闭后质检仅使用本机知识库。若网络不可达（维基百科在部分网络环境下无法访问），检索会被自动跳过，质检结论将基于本机资料与模型知识。

六、数据存储与丢失风险

笔记、转写稿、译文、总结保存在你手机的本地数据库中；本应用没有账号体系，也不向作者自建的服务器上传任何数据。

卸载应用、清除应用数据、更换手机、系统故障或误操作，都可能造成数据永久丢失。请对重要笔记自行导出备份。

本应用会申请麦克风权限、录音前台服务与通知权限，仅用于录音与显示录音状态。

七、开源许可与担保排除

本应用以 MIT 许可证开源。在适用法律允许的最大范围内：

1. 本应用按「现状」提供，不附带任何明示或默示的担保，包括但不限于适销性、特定用途适用性与不侵权的担保；
2. 作者不保证应用无错误、不中断、不丢失数据，也不保证识别或生成结果准确；
3. 作者不对因使用或无法使用本应用而产生的任何直接、间接、附带、特殊或后果性损失承担责任，包括但不限于成绩受损、数据丢失、设备损坏、第三方索赔。

八、责任限制

在适用法律允许的范围内，你同意：因你使用本应用（包括录音行为、AI 生成内容的使用、向第三方服务提交数据）引起的任何索赔、纠纷、处罚或损失，由你自行承担；作者不承担赔偿责任。

本条款不排除依法不能排除的责任。

九、未成年人

如果你未满 18 周岁，请在监护人阅读并同意本声明后再使用。

十、条款更新与同意记录

本声明可能随功能变化更新，版本号写在本页顶部。你在应用内的同意动作会在本机记录同意的版本号与时间，不会上传。版本更新后，应用会再次要求你确认；不同意更新后的条款，请停止使用并卸载。

十一、其他

本声明不构成法律意见。若你需要确认其在所在地区的效力，请咨询专业律师。若本声明部分条款被认定无效，其余条款仍然有效。如不同意本声明任何内容，请立即卸载本应用并不再使用。

再次提醒：录课前先征得老师与同学同意；AI 生成的内容一定要自己核对。
''';
}

class DisclaimerPage extends StatefulWidget {
  const DisclaimerPage({
    super.key,
    required this.onAccepted,
    this.readOnly = false,
  });

  /// 同意后回调。首次启动时由 StartupGate 用它切到首页。
  final VoidCallback onAccepted;

  /// 从设置页进入时为只读：只展示，不再要求勾选。
  final bool readOnly;

  @override
  State<DisclaimerPage> createState() => _DisclaimerPageState();
}

class _DisclaimerPageState extends State<DisclaimerPage> {
  bool _agreed = false;
  bool _saving = false;

  Future<void> _accept() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await SettingsService().acceptDisclaimer(Disclaimer.version);
    } catch (_) {
      // 本地存储写失败（极少数机型/空间不足）：不能假装签过了，
      // 否则下次启动又会弹，用户会以为"签了没用"
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存同意记录失败，请重试')),
      );
      return;
    }
    if (!mounted) return;
    widget.onAccepted();
  }

  Future<void> _refuse() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('不同意就无法使用'),
        content: const Text(
          '本应用需要录音并把内容发送给第三方 AI 服务，'
          '在你同意这些条款前不能使用。\n\n现在退出并卸载吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再看看'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      // Android 上退出到桌面；iOS 无此语义，会退化为无操作
      await SystemNavigator.pop();
    }
  }

  String _formatTime(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final acceptedVersion = SettingsService.lastAcceptedVersion;
    final acceptedAt = SettingsService.lastAcceptedAt;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.readOnly ? '免责声明' : '使用前请阅读'),
        automaticallyImplyLeading: widget.readOnly,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!widget.readOnly)
              Container(
                width: double.infinity,
                color: Colors.amber.shade50,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  '录课前必须征得老师与在场同学同意；转写与翻译由 AI 生成，'
                  '可能有错，考试与作业内容请自行核对。',
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: Colors.amber.shade900),
                ),
              ),
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: SelectableText(
                  Disclaimer.text,
                  style: TextStyle(fontSize: 13, height: 1.75),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: widget.readOnly
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (acceptedVersion != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '已同意版本 $acceptedVersion'
                              '${acceptedAt == null ? '' : ' · ${_formatTime(acceptedAt)}'}',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.grey.shade600),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('返回'),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CheckboxListTile(
                          value: _agreed,
                          onChanged: (v) =>
                              setState(() => _agreed = v ?? false),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            '我已完整阅读并同意上述全部条款',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _saving ? null : _refuse,
                                child: const Text('不同意'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton(
                                onPressed:
                                    (_agreed && !_saving) ? _accept : null,
                                child: Text(_saving ? '记录中…' : '同意并继续'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}