import type { StructureType } from '../../src/types';

/**
 * 测试计划要求的 20 条样本。
 *
 * **来源与局限**：这些样本是从《场景分析.md》的场景清单与《测试计划.md》的 bad case
 * 类别推导出来的**代表性样本**，不是用户真机上的真实录入。它们的用途是：
 *   1. 给 20 条样本一个可执行的载体（此前只有类别、没有逐条清单）；
 *   2. 让 `live-gateway.test.ts` 能对真模型跑出各种比率。
 * 用户攒到真实素材后应当替换或校准这里的 input，期望值维持不变。
 */

export type BadCase =
  | 'dialect' // 方言或含口音的口述转写（错别字密集）
  | 'closeup_only' // 只拍了特写、没有远景（层级缺失）
  | 'multi_item' // 一段话里塞了 3 件物品（验证单主卡 + 次要物品进 desc/tags）
  | 'procedure' // 纯流程类
  | 'todo' // 纯待办类
  | 'photo_only' // 完全无语音、只有照片
  | 'text_only_off' // 图片分析关闭 + 纯文本录入
  | 'alias' // 口述用的是别称，检索要用另一个叫法
  | 'short_term'; // 两字词，必须走 LIKE 降级

export interface SampleExpectation {
  structureType?: StructureType;
  category?: string;
  /** 检索时应当命中本条（用 entity 判等） */
  shouldHit?: boolean;
  /** 期望 ask 为空 / 非空；不填则不检查 */
  askEmpty?: boolean;
  /** 期望 path 命中已有位置树 */
  pathMatched?: boolean;
}

export interface Sample {
  id: string;
  bad: BadCase;
  /** 录入时用户说的话（可能含错别字） */
  transcript: string;
  /** 图片张数（真机样本里对应实际素材，这里只记数量与用途） */
  imageCount: number;
  imageNote?: string;
  /** 图片分析开关；false 表示这次不送图 */
  vision: boolean;
  /** 检索问句 */
  query: string;
  expectation: SampleExpectation;
}

export const SAMPLES: readonly Sample[] = [
  {
    id: 's01',
    bad: 'dialect',
    transcript: '羽绒服抽真空塞主卧衣柜顶上了，跟去年那件长款的搁一块儿',
    imageCount: 3,
    imageNote: '衣柜全貌 → 柜内 → 真空袋特写',
    vision: true,
    query: '我那件厚外套放哪了',
    expectation: { structureType: 'item', category: '物品存取', shouldHit: true, pathMatched: true },
  },
  {
    id: 's02',
    bad: 'closeup_only',
    transcript: '手电筒搁这儿了',
    imageCount: 1,
    imageNote: '只拍了纸箱内部特写，没有房间远景',
    vision: true,
    query: '手电筒在哪',
    expectation: { structureType: 'item', category: '物品存取', shouldHit: true, pathMatched: false },
  },
  {
    id: 's03',
    bad: 'multi_item',
    transcript: '这几样都收在这个箱子里了：手电筒、电池、还有急救包',
    imageCount: 2,
    vision: true,
    query: '急救包在哪',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's04',
    bad: 'procedure',
    transcript: '换驾照要先在交管12123上预约，然后带身份证、旧驾照、体检表去车管所，现场拍照缴费，三天后取证',
    imageCount: 0,
    vision: true,
    query: '换驾照要带什么材料',
    expectation: { structureType: 'procedure', category: '流程备忘', shouldHit: true, pathMatched: false },
  },
  {
    id: 's05',
    bad: 'procedure',
    transcript: '净水器滤芯半年换一次，先关进水阀，拧开滤芯壳，取出旧芯，新芯要竖着插到底，再拧紧通水放五分钟',
    imageCount: 4,
    imageNote: '多张截图：滤芯型号、拆装步骤',
    vision: true,
    query: '滤芯怎么换',
    expectation: { structureType: 'procedure', category: '流程备忘', shouldHit: true },
  },
  {
    id: 's06',
    bad: 'todo',
    transcript: '猫砂见底了，该买猫砂了',
    imageCount: 1,
    vision: true,
    query: '有什么要买的',
    expectation: { structureType: 'todo', category: '待买补货', shouldHit: true, pathMatched: false },
  },
  {
    id: 's07',
    bad: 'todo',
    transcript: '出门前记得带上充电宝和降噪耳机',
    imageCount: 0,
    vision: true,
    query: '出门要带什么',
    expectation: { structureType: 'todo', shouldHit: true },
  },
  {
    id: 's08',
    bad: 'photo_only',
    transcript: '',
    imageCount: 3,
    imageNote: '只有照片：书架 → 抽屉 → 证件袋特写',
    vision: true,
    query: '护照放哪了',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's09',
    bad: 'short_term',
    transcript: '备用钥匙放在玄关鞋柜的抽屉里',
    imageCount: 1,
    vision: true,
    query: '钥匙在哪',
    expectation: { structureType: 'item', category: '物品存取', shouldHit: true, pathMatched: true },
  },
  {
    id: 's10',
    bad: 'short_term',
    transcript: '猫砂囤了两袋，放在阳台储物柜下层',
    imageCount: 1,
    vision: true,
    query: '猫砂放哪了',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's11',
    bad: 'alias',
    transcript: '那个应急灯搁主卧衣柜最下面纸箱里了',
    imageCount: 1,
    vision: true,
    query: '手电筒在哪',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's12',
    bad: 'alias',
    transcript: '出入境的证件都收在书房抽屉的文件袋里',
    imageCount: 1,
    vision: true,
    query: '我护照呢',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's13',
    bad: 'dialect',
    transcript: '螺丝刀跟扳手都搁工具箱里头了，箱子里还有一卷3M胶',
    imageCount: 1,
    vision: true,
    query: '螺丝刀在哪',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's14',
    bad: 'closeup_only',
    transcript: '这是灯泡型号',
    imageCount: 1,
    imageNote: '只拍了灯泡底部型号特写',
    vision: true,
    query: '客厅灯泡什么型号',
    expectation: { structureType: 'item', shouldHit: true, pathMatched: false },
  },
  {
    id: 's15',
    bad: 'procedure',
    transcript: '路由器重置：先按住reset十秒，灯闪了松手，然后浏览器进192.168.1.1，账号密码在机器背面，进去改WiFi名和密码',
    imageCount: 1,
    vision: true,
    query: '路由器怎么重置',
    expectation: { structureType: 'procedure', shouldHit: true },
  },
  {
    id: 's16',
    bad: 'todo',
    transcript: '帮妈买降压药，下周三之前',
    imageCount: 0,
    vision: true,
    query: '要帮谁买什么',
    expectation: { structureType: 'todo', shouldHit: true },
  },
  {
    id: 's17',
    bad: 'photo_only',
    transcript: '',
    imageCount: 5,
    imageNote: '报销系统操作截图 5 张',
    vision: true,
    query: '报销怎么操作',
    expectation: { structureType: 'procedure', shouldHit: true },
  },
  {
    id: 's18',
    bad: 'text_only_off',
    transcript: '圣诞装饰收在储藏间最里面的塑料箱',
    imageCount: 2,
    imageNote: '关了图片分析，图片只作附件',
    vision: false,
    query: '圣诞装饰在哪',
    expectation: { structureType: 'item', shouldHit: true },
  },
  {
    id: 's19',
    bad: 'text_only_off',
    transcript: '交物业费在公众号上，先绑定房号，然后选缴费年度',
    imageCount: 0,
    vision: false,
    query: '物业费怎么交',
    expectation: { structureType: 'procedure', shouldHit: true },
  },
  {
    id: 's20',
    bad: 'dialect',
    transcript: '梯子借给隔壁老王家了，说下周还',
    imageCount: 0,
    vision: true,
    query: '梯子在谁那',
    expectation: { structureType: 'item', shouldHit: true, pathMatched: false },
  },
];

/** 覆盖《测试计划.md》第二节要求的全部 bad case 类别 */
export const REQUIRED_BAD_CASES: readonly BadCase[] = [
  'dialect',
  'closeup_only',
  'multi_item',
  'procedure',
  'todo',
  'photo_only',
  'text_only_off',
];
