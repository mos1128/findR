/// 测试计划要求的 20 条样本 —— 逐字对应 `packages/core/test/fixtures/samples.ts`（261 行）。
///
/// **来源与局限**：这些样本是从《场景分析.md》的场景清单与《测试计划.md》的 bad case
/// 类别推导出来的**代表性样本**，不是用户真机上的真实录入。它们的用途是：
///   1. 给 20 条样本一个可执行的载体（此前只有类别、没有逐条清单）；
///   2. 让真机/真模型的联调能对样本跑出各种比率。
/// 用户攒到真实素材后应当替换或校准这里的 input，**期望值维持不变**。
///
/// 2026-09-18：期望值里的 `structureType` 换成了 `hasLocation`。原因见《开发交接.md》——
/// 结构类型已从产品里整体去掉，而原先「item 必有位置」这条约束改成了**由内容判断**，
/// 所以这里改成盯「这条素材里到底有没有位置信息」，这才是现在真正要考验模型的点。
library;

/// 《测试计划.md》第二节要求的 bad case 类别。
///
/// TS 侧是字符串 union，Dart 用 enum；[wire] 保留原始字面值，断言与报错信息里都用它。
enum BadCase {
  /// 方言或含口音的口述转写（错别字密集）。
  dialect('dialect'),

  /// 只拍了特写、没有远景（层级缺失）。
  closeupOnly('closeup_only'),

  /// 一段话里塞了 3 件物品（验证单主卡 + 次要物品进 desc/tags）。
  multiItem('multi_item'),

  /// 纯流程类。
  procedure('procedure'),

  /// 纯待办类。
  todo('todo'),

  /// 完全无语音、只有照片。
  photoOnly('photo_only'),

  /// 图片分析关闭 + 纯文本录入。
  textOnlyOff('text_only_off'),

  /// 口述用的是别称，检索要用另一个叫法。
  alias('alias'),

  /// 两字词，必须走 LIKE 降级。
  shortTerm('short_term');

  const BadCase(this.wire);

  final String wire;
}

/// 一条样本的期望值。
final class SampleExpectation {
  const SampleExpectation({
    this.category,
    this.shouldHit,
    this.askEmpty,
    this.pathMatched,
    this.hasLocation,
  });

  final String? category;

  /// 检索时应当命中本条（用 entity 判等）。
  final bool? shouldHit;

  /// 期望 ask 为空 / 非空；null 则不检查。
  final bool? askEmpty;

  /// 期望 path 命中已有位置树。
  final bool? pathMatched;

  /// 这条素材里是否存在「东西放在哪」的明确信息。
  ///
  /// true ⇒ 模型应当给出 path（匹配得到就复用，匹配不到就新建层级）；
  /// false ⇒ 模型**不该**为了凑字段硬猜一个房间，宁可用 path_suggestion 交给用户确认。
  /// 这正是去掉结构类型之后新增的那条规则，靠这几条样本盯着。
  final bool? hasLocation;
}

/// 一条手工样本。
final class Sample {
  const Sample({
    required this.id,
    required this.bad,
    required this.transcript,
    required this.imageCount,
    this.imageNote,
    required this.vision,
    required this.query,
    required this.expectation,
  });

  final String id;
  final BadCase bad;

  /// 录入时用户说的话（可能含错别字）。
  final String transcript;

  /// 图片张数（真机样本里对应实际素材，这里只记数量与用途）。
  final int imageCount;

  final String? imageNote;

  /// 图片分析开关；false 表示这次不送图。
  final bool vision;

  /// 检索问句。
  final String query;

  final SampleExpectation expectation;
}

const List<Sample> samples = <Sample>[
  Sample(
    id: 's01',
    bad: BadCase.dialect,
    transcript: '羽绒服抽真空塞主卧衣柜顶上了，跟去年那件长款的搁一块儿',
    imageCount: 3,
    imageNote: '衣柜全貌 → 柜内 → 真空袋特写',
    vision: true,
    query: '我那件厚外套放哪了',
    expectation: SampleExpectation(
      hasLocation: true,
      category: '物品存取',
      shouldHit: true,
      pathMatched: true,
    ),
  ),
  Sample(
    id: 's02',
    bad: BadCase.closeupOnly,
    transcript: '手电筒搁这儿了',
    imageCount: 1,
    imageNote: '只拍了纸箱内部特写，没有房间远景',
    vision: true,
    query: '手电筒在哪',
    // 文字只说「这儿」，图上只有特写 ⇒ 判定不出房间，不该硬猜
    expectation: SampleExpectation(
      hasLocation: false,
      category: '物品存取',
      shouldHit: true,
      pathMatched: false,
    ),
  ),
  Sample(
    id: 's03',
    bad: BadCase.multiItem,
    transcript: '这几样都收在这个箱子里了：手电筒、电池、还有急救包',
    imageCount: 2,
    vision: true,
    query: '急救包在哪',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's04',
    bad: BadCase.procedure,
    transcript: '换驾照要先在交管12123上预约，然后带身份证、旧驾照、体检表去车管所，现场拍照缴费，三天后取证',
    imageCount: 0,
    vision: true,
    query: '换驾照要带什么材料',
    expectation: SampleExpectation(
      hasLocation: false,
      category: '流程备忘',
      shouldHit: true,
      pathMatched: false,
    ),
  ),
  Sample(
    id: 's05',
    bad: BadCase.procedure,
    transcript: '净水器滤芯半年换一次，先关进水阀，拧开滤芯壳，取出旧芯，新芯要竖着插到底，再拧紧通水放五分钟',
    imageCount: 4,
    imageNote: '多张截图：滤芯型号、拆装步骤',
    vision: true,
    query: '滤芯怎么换',
    expectation: SampleExpectation(hasLocation: false, category: '流程备忘', shouldHit: true),
  ),
  Sample(
    id: 's06',
    bad: BadCase.todo,
    transcript: '猫砂见底了，该买猫砂了',
    imageCount: 1,
    vision: true,
    query: '有什么要买的',
    expectation: SampleExpectation(
      hasLocation: false,
      category: '待买补货',
      shouldHit: true,
      pathMatched: false,
    ),
  ),
  Sample(
    id: 's07',
    bad: BadCase.todo,
    transcript: '出门前记得带上充电宝和降噪耳机',
    imageCount: 0,
    vision: true,
    query: '出门要带什么',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's08',
    bad: BadCase.photoOnly,
    transcript: '',
    imageCount: 3,
    imageNote: '只有照片：书架 → 抽屉 → 证件袋特写',
    vision: true,
    query: '护照放哪了',
    // 文字为空，但照片本身串起了书架 / 抽屉 / 证件袋 ⇒ 视觉应当给出位置
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's09',
    bad: BadCase.shortTerm,
    transcript: '备用钥匙放在玄关鞋柜的抽屉里',
    imageCount: 1,
    vision: true,
    query: '钥匙在哪',
    expectation: SampleExpectation(
      hasLocation: true,
      category: '物品存取',
      shouldHit: true,
      pathMatched: true,
    ),
  ),
  Sample(
    id: 's10',
    bad: BadCase.shortTerm,
    transcript: '猫砂囤了两袋，放在阳台储物柜下层',
    imageCount: 1,
    vision: true,
    query: '猫砂放哪了',
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's11',
    bad: BadCase.alias,
    transcript: '那个应急灯搁主卧衣柜最下面纸箱里了',
    imageCount: 1,
    vision: true,
    query: '手电筒在哪',
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's12',
    bad: BadCase.alias,
    transcript: '出入境的证件都收在书房抽屉的文件袋里',
    imageCount: 1,
    vision: true,
    query: '我护照呢',
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's13',
    bad: BadCase.dialect,
    transcript: '螺丝刀跟扳手都搁工具箱里头了，箱子里还有一卷3M胶',
    imageCount: 1,
    vision: true,
    query: '螺丝刀在哪',
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's14',
    bad: BadCase.closeupOnly,
    transcript: '这是灯泡型号',
    imageCount: 1,
    imageNote: '只拍了灯泡底部型号特写',
    vision: true,
    query: '客厅灯泡什么型号',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true, pathMatched: false),
  ),
  Sample(
    id: 's15',
    bad: BadCase.procedure,
    transcript: '路由器重置：先按住reset十秒，灯闪了松手，然后浏览器进192.168.1.1，账号密码在机器背面，进去改WiFi名和密码',
    imageCount: 1,
    vision: true,
    query: '路由器怎么重置',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's16',
    bad: BadCase.todo,
    transcript: '帮妈买降压药，下周三之前',
    imageCount: 0,
    vision: true,
    query: '要帮谁买什么',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's17',
    bad: BadCase.photoOnly,
    transcript: '',
    imageCount: 5,
    imageNote: '报销系统操作截图 5 张',
    vision: true,
    query: '报销怎么操作',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's18',
    bad: BadCase.textOnlyOff,
    transcript: '圣诞装饰收在储藏间最里面的塑料箱',
    imageCount: 2,
    imageNote: '关了图片分析，图片只作附件',
    vision: false,
    query: '圣诞装饰在哪',
    expectation: SampleExpectation(hasLocation: true, shouldHit: true),
  ),
  Sample(
    id: 's19',
    bad: BadCase.textOnlyOff,
    transcript: '交物业费在公众号上，先绑定房号，然后选缴费年度',
    imageCount: 0,
    vision: false,
    query: '物业费怎么交',
    expectation: SampleExpectation(hasLocation: false, shouldHit: true),
  ),
  Sample(
    id: 's20',
    bad: BadCase.dialect,
    transcript: '梯子借给隔壁老王家了，说下周还',
    imageCount: 0,
    vision: true,
    query: '梯子在谁那',
    // 「借给谁」不是存放位置 —— 去掉关联人字段后，这句只该体现在 desc 里，不该变出 path
    expectation: SampleExpectation(hasLocation: false, shouldHit: true, pathMatched: false),
  ),
];

/// 覆盖《测试计划.md》第二节要求的全部 bad case 类别。
const List<BadCase> requiredBadCases = <BadCase>[
  BadCase.dialect,
  BadCase.closeupOnly,
  BadCase.multiItem,
  BadCase.procedure,
  BadCase.todo,
  BadCase.photoOnly,
  BadCase.textOnlyOff,
];
