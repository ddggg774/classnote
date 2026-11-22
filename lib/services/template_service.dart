// lib/services/template_service.dart
// 模板注册与选取：内置模板 + 用户自定义模板。
//
// 【内置模板为什么用代码常量而不是存数据库】
// 内置模板是产品定义的一部分，跟着版本走。存数据库的话：
//   · 每次升级都要写迁移把新版模板灌进去
//   · 用户误改了就回不去
// 所以内置模板写死在代码里（builtin=true），用户想改用「复制成自定义」再改。
//
// 【模板选择的优先级】
// 用户显式选 > 课程绑定 > 通用默认（九段式）。
// 不做太聪明的自动推断——猜错比让用户选更烦人。
import '../config.dart';
import '../models/note_template.dart';

/// 内置模板 ID（避免各处硬编码字符串拼错）
class BuiltinTemplate {
  const BuiltinTemplate._();
  static const String general = 'builtin-general';
  static const String brief = 'builtin-brief';
  static const String lab = 'builtin-lab';
  static const String drawing = 'builtin-drawing';
}

class TemplateService {
  TemplateService();

  /// 全部内置模板（顺序即界面顺序）
  static const List<NoteTemplate> builtins = [
    // ─────────── 1. 九段式（通用默认，与现有 prompt 一致） ───────────
    NoteTemplate(
      id: BuiltinTemplate.general,
      name: '九段式',
      scene: '通用课堂。信息最全，适合需要完整复习的课',
      sections: [
        TemplateSection(
          title: '课程信息',
          requirements: ['课程名 / 本节主题 / 学习目标 / 与前后知识的关联'],
        ),
        TemplateSection(
          title: '知识点结构',
          requirements: [
            '按层级组织（## 一级知识点、### 二级）',
            '每个知识点包含：概念定义、公式/定理（如有，保留原式）、推导步骤、适用条件、老师强调点',
            '写出逻辑关系：前后知识点怎么连起来的',
          ],
        ),
        TemplateSection(
          title: '例题与解题步骤',
          required: false,
          requirements: [
            '每道例题用字段：题干 / 解题思路 / 关键步骤 / 答案 / 易错点',
            '步骤缺失必须标注〔转写缺失〕，答案不确定写〔待确认〕',
          ],
        ),
        TemplateSection(
          title: '老师强调与考试作业提示',
          requirements: [
            '重点 / 难点 / 易错点',
            '考试范围',
            '作业要求 / 提交方式 / 截止时间（没提到就写「未提及」）',
          ],
        ),
        TemplateSection(
          title: '课堂互动问答',
          required: false,
          requirements: ['逐条列：学生问 → 老师答 → 结论'],
        ),
        TemplateSection(
          title: '术语/公式/英文缩写表',
          required: false,
          needTable: true,
          requirements: ['表头：| 术语 | 原文中的位置或片段 | 简要解释 |'],
        ),
        TemplateSection(
          title: '学习任务表',
          required: false,
          needTable: true,
          requirements: [
            '表头：| 任务 | 类型(作业/预习/复习) | 截止时间 | 提交方式 |',
            '没有的内容一律写「未提及」',
          ],
        ),
        TemplateSection(
          title: '疑问与待确认清单',
          required: false,
          requirements: [
            '逐条列：- 位置/原文片段：不确定的原因 → `待确认`',
          ],
        ),
        TemplateSection(
          title: '时间戳回溯',
          required: false,
          requirements: ['关键知识点、例题、作业考试提示的时间点或原文片段索引'],
        ),
      ],
      builtin: true,
      sortOrder: 0,
    ),

    // ─────────── 2. 速览（考前扫一眼用） ───────────
    NoteTemplate(
      id: BuiltinTemplate.brief,
      name: '速览',
      scene: '考前快速回顾。只留知识点与考试提示，一屏看完',
      sections: [
        TemplateSection(
          title: '课程信息',
          requirements: ['课程名 / 本节主题'],
        ),
        TemplateSection(
          title: '知识点结构',
          requirements: [
            '按层级列出核心知识点',
            '只写知识点名称与一句话定义，**不展开推导、不写例题**',
          ],
        ),
        TemplateSection(
          title: '老师强调与考试作业提示',
          requirements: [
            '重点 / 易错点 / 考试范围 / 作业要求与截止时间（没提到写「未提及」）',
          ],
        ),
      ],
      builtin: true,
      sortOrder: 1,
    ),

    // ─────────── 3. 实验/实习报告 ───────────
    NoteTemplate(
      id: BuiltinTemplate.lab,
      name: '实验/实习报告',
      scene: '实验课、实习课。按报告格式记录，适合植物学野外实习、标本制作',
      sections: [
        TemplateSection(
          title: '实验目的与原理',
          requirements: [
            '这次实验/实习要解决什么问题',
            '依据的原理或理论（原文没讲就写「未提及」）',
          ],
        ),
        TemplateSection(
          title: '材料与仪器',
          needTable: true,
          requirements: [
            '表头：| 名称 | 规格/数量 | 用途 |',
            '植物学实习注意记录：采集工具、标本夹、固定液、放大镜/显微镜等',
          ],
        ),
        TemplateSection(
          title: '方法与操作步骤',
          requirements: [
            '按老师讲的顺序逐步记录，每步写清「做什么 + 注意什么」',
            '关键参数（时间、温度、浓度、比例）必须原样保留，不确定的标〔待确认〕',
            '步骤缺失处标〔转写缺失〕，不要自行补全流程',
          ],
        ),
        TemplateSection(
          title: '结果与观察记录',
          requirements: [
            '老师给出的示范结果、数据、观察到的现象',
            '植物学记录形态特征时，拉丁学名保留双名法原样',
          ],
        ),
        TemplateSection(
          title: '讨论与误差分析',
          required: false,
          requirements: [
            '老师提到的易错操作、常见失败原因',
            '与理论预期的差异及可能原因',
          ],
        ),
        TemplateSection(
          title: '结论',
          requirements: ['用一两句话总结本次实验得出什么'],
        ),
        TemplateSection(
          title: '安全与注意事项',
          required: false,
          requirements: [
            '老师强调的安全事项、试剂/器械使用禁忌',
            '野外实习的采集规范与保护要求',
          ],
        ),
      ],
      builtin: true,
      sortOrder: 2,
    ),

    // ─────────── 4. 制图与规范（建筑制图 / 园林制图专用） ───────────
    NoteTemplate(
      id: BuiltinTemplate.drawing,
      name: '制图与规范',
      scene: '建筑制图、园林制图。侧重图名、线型、标注与规范条文',
      course: '制图',
      sections: [
        TemplateSection(
          title: '图纸类型与图名',
          requirements: [
            '本次讲的是什么图（平面图/立面图/剖面图/详图/总平面图/种植图等）',
            '图名写法与命名规则',
            '制图类型不明确时标「待确认」，**不要编造**',
          ],
        ),
        TemplateSection(
          title: '图幅、比例与图纸规格',
          requirements: [
            '图幅代号（A0/A1/A2/A3/A4）与尺寸，原文给了就照抄',
            '常用比例及其适用场景',
            '标题栏、会签栏的位置与内容',
          ],
        ),
        TemplateSection(
          title: '线型与线宽',
          needTable: true,
          requirements: [
            '表头：| 线型名称 | 线宽(b) | 用途 |',
            '粗实线/中实线/细实线/虚线/点划线/折断线/波浪线等，按老师讲的分类',
            '**不编造线型代号**，原文没提就留空并标「未提及」',
          ],
        ),
        TemplateSection(
          title: '尺寸标注规则',
          requirements: [
            '尺寸线、尺寸界线、尺寸起止符的画法与间距要求',
            '标注数字的方向、单位（标高以米计、其余以毫米计等）',
            '索引符号、详图符号、剖切符号的编号规则',
          ],
        ),
        TemplateSection(
          title: '投影与视图关系',
          required: false,
          requirements: [
            '正投影的三面投影规律（长对正、高平齐、宽相等）',
            '视图配置与剖视/断面图的选择原则',
          ],
        ),
        TemplateSection(
          title: '常见错误',
          required: false,
          requirements: [
            '老师点出的典型错误（线型混用、标注漏项、比例不符等）',
            '扣分点',
          ],
        ),
        TemplateSection(
          title: '作业要求',
          requirements: [
            '本次作图任务的具体要求（画什么图、几张、比例、图幅）',
            '提交方式与截止时间（没提到写「未提及」）',
          ],
        ),
      ],
      builtin: true,
      sortOrder: 3,
    ),
  ];

  /// 按 ID 找内置模板
  static NoteTemplate? builtinById(String id) {
    for (final t in builtins) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 默认模板（九段式）
  static NoteTemplate get defaultTemplate => builtins.first;

  /// 为某课程推荐模板：课程绑定的优先，否则九段式。
  ///
  /// 刻意不做"猜"的动作——只有模板自己声明了 course 且能匹配上才算命中。
  static NoteTemplate recommendFor(String courseName) {
    final c = courseName.trim();
    if (c.isNotEmpty) {
      // 课程绑定优先，按 sortOrder 取第一个命中的
      for (final t in builtins) {
        if (t.course.isNotEmpty && t.matchesCourse(c)) return t;
      }
    }
    return defaultTemplate;
  }

  /// 从「课程名」反推教材信息（复用 AppConfig，保持单一事实来源）
  static String textbookLine(String courseName) =>
      AppConfig.textbookLine(courseName);

  /// 校验用户自定义模板（界面上保存前调用）
  /// 返回 null 表示通过，否则返回错误说明。
  static String? validate(NoteTemplate t) {
    if (t.name.trim().isEmpty) return '模板名不能为空';
    if (t.sections.isEmpty) return '至少要有一节';
    final titles = <String>{};
    for (final s in t.sections) {
      final title = s.title.trim();
      if (title.isEmpty) return '有章节标题为空';
      if (!titles.add(title)) return '章节标题重复：$title';
    }
    if (!t.sections.any((s) => s.required)) {
      return '至少要有一节是必需的，否则可能生成空笔记';
    }
    return null;
  }

  /// 合并内置与自定义模板，按 sortOrder 排序（内置在前）
  static List<NoteTemplate> merge({
    required List<NoteTemplate> custom,
  }) {
    final all = <NoteTemplate>[...builtins, ...custom];
    all.sort((a, b) {
      // 内置优先，其次按 sortOrder，最后按名称
      if (a.builtin != b.builtin) return a.builtin ? -1 : 1;
      final c = a.sortOrder.compareTo(b.sortOrder);
      if (c != 0) return c;
      return a.name.compareTo(b.name);
    });
    return all;
  }
}