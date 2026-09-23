#!/usr/bin/env node
// 离线自测：用合成样本跑一遍生成器，验证解析、打分、去重、日期过滤、输出格式。
// 不联网，随时可以跑：node tools/selftest.mjs

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'digest-selftest-'));

const failures = [];
function check(name, condition, detail = '') {
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
    failures.push(name);
  }
}

function daysAgo(days) {
  return new Date(Date.now() - days * 24 * 3600 * 1000);
}

function rssDate(date) {
  const shifted = new Date(date.getTime() + 8 * 3600 * 1000);
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (value) => String(value).padStart(2, '0');
  return `${weekdays[shifted.getUTCDay()]}, ${pad(shifted.getUTCDate())} ${months[shifted.getUTCMonth()]} ${shifted.getUTCFullYear()} ${pad(shifted.getUTCHours())}:${pad(shifted.getUTCMinutes())}:00 +0800`;
}

// 有些源（例如新华网那份 RSS）根本不带 pubDate，日期只能从链接里看出来。
function rss(items, options = {}) {
  const withDate = options.withDate !== false;
  const entries = items
    .map((item) => {
      const dateLine = withDate ? `\n      <pubDate>${rssDate(item.date)}</pubDate>` : '';
      return `    <item>
      <title><![CDATA[${item.title}]]></title>
      <link>${item.link}</link>${dateLine}
      <description><![CDATA[<p>${item.summary || ''}</p>]]></description>
    </item>`;
    })
    .join('\n');
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>样本频道</title>
${entries}
  </channel>
</rss>
`;
}

function ymd(date) {
  return date.toISOString().slice(0, 10);
}

// ---------- 样本数据 ----------

const policyItems = [
  {
    title: '国务院常务会议部署稳就业稳经济措施',
    link: 'https://www.gov.cn/zhengce/test-1.shtml',
    summary: '会议指出要突出就业优先导向，加大对民营经济支持力度，扩大有效投资，巩固经济回升向好态势。',
    date: daysAgo(0)
  },
  {
    title: '中央政治局会议分析研究当前经济形势',
    link: 'https://www.gov.cn/zhengce/test-2.shtml',
    summary: '会议强调要实施更加积极的财政政策和适度宽松的货币政策，着力扩大内需、提振消费。',
    date: daysAgo(0)
  },
  {
    title: '国务院印发关于推进乡村振兴重点工作的意见',
    link: 'https://www.gov.cn/zhengce/test-3.shtml',
    summary: '文件提出稳定粮食播种面积、加强耕地保护、促进农业转移人口市民化等举措。',
    date: daysAgo(1)
  },
  {
    title: '多部门联合发布促进人工智能产业发展举措',
    link: 'https://www.gov.cn/zhengce/test-4.shtml',
    summary: '围绕算力、芯片、数据要素等方向提出支持政策，加快培育新质生产力。',
    date: daysAgo(1)
  }
];

const newsItems = [
  {
    title: '全国人大常委会通过新修订的行政法规',
    link: 'https://example.gov.cn/news/test-5.shtml',
    summary: '条例进一步明确依法办事要求，健全监察与司法衔接机制。',
    date: daysAgo(0)
  },
  {
    title: '我国前三季度外贸出口数据发布',
    link: 'https://example.gov.cn/news/test-6.shtml',
    summary: '海关总署数据显示，出口保持增长，新能源产品出口表现突出。',
    date: daysAgo(0)
  },
  {
    title: '生态环境部发布会介绍碳达峰碳中和进展',
    link: 'https://example.gov.cn/news/test-7.shtml',
    summary: '相关部门介绍能源保供与绿色转型情况，长江、黄河生态治理取得进展。',
    date: daysAgo(1)
  },
  {
    title: '医保局公布门诊费用跨省结算新政策',
    link: 'https://example.gov.cn/news/test-8.shtml',
    summary: '新政策扩大医保覆盖范围，减轻群众医疗负担，涉及养老与救助衔接。',
    date: daysAgo(1)
  },
  {
    title: '外交部就双边关系与全球治理表态',
    link: 'https://example.gov.cn/news/test-9.shtml',
    summary: '发言人介绍上合组织峰会筹备情况与一带一路合作新进展。',
    date: daysAgo(2)
  },
  {
    title: '某地举办秋季美食节吸引游客',
    link: 'https://example.gov.cn/news/test-10.shtml',
    summary: '现场设有小吃摊位与灯光表演，周末客流量明显增加。',
    date: daysAgo(2)
  },
  {
    title: '国际足球邀请赛本周末开赛',
    link: 'https://example.gov.cn/news/test-11.shtml',
    summary: '赛事将在三个城市举行，门票已开始发售。',
    date: daysAgo(3)
  },
  {
    title: '教育部部署高校思政课建设相关工作',
    link: 'https://example.gov.cn/news/test-12.shtml',
    summary: '要求用好文化遗产资源，推动教育与文化传承结合。',
    date: daysAgo(1)
  }
];

// 僵尸源：不带 pubDate，链接里全是 2022 年的旧闻，必须被拒之门外。
const staleItems = [
  {
    title: '2022年某会议研究部署经济工作',
    link: 'https://www.news.cn/politics/2022-12/12/c_1129200762.htm',
    summary: '这是三年前的旧闻，不该出现在今天的要点里。'
  },
  {
    title: '2022年某部门发布行业管理办法',
    link: 'https://www.news.cn/politics/2022-12/10/c_1129198984.htm',
    summary: '同样是旧闻。'
  }
];

// 央视接口样本：自带 brief 摘要与 keywords。
const cctvItems = [
  {
    id: 'A1',
    title: '国务院部署扩大内需促进消费系列举措',
    brief: '会议提出着力扩大国内需求，推动消费持续恢复，加大对民营经济和制造业的信贷支持力度。',
    keywords: '扩大内需 消费 民营经济',
    focus_date: `${ymd(daysAgo(0))} 10:18:31`,
    url: 'https://news.cctv.com/2026/09/23/ARTI1.shtml'
  },
  {
    id: 'A2',
    title: '多部门联合出台措施稳定制造业产业链',
    brief: '围绕产业链安全与转型升级提出支持政策，重点保障就业与外贸企业融资需求。',
    keywords: '制造业 产业链 稳增长',
    focus_date: `${ymd(daysAgo(0))} 09:02:10`,
    url: 'https://news.cctv.com/2026/09/23/ARTI2.shtml'
  },
  {
    id: 'A3',
    title: '国家医保局回应门诊统筹与药品集采进展',
    brief: '相关负责人介绍医保基金运行情况，回应群众关心的门诊报销与药品价格问题。',
    keywords: '医保 民生',
    focus_date: `${ymd(daysAgo(1))} 16:40:00`,
    url: 'https://news.cctv.com/2026/09/22/ARTI3.shtml'
  },
  {
    id: 'A4',
    title: '我国前三季度进出口数据公布',
    brief: '海关总署公布前三季度外贸数据，出口结构持续优化，新能源产品表现突出。',
    keywords: '外贸 出口 新能源',
    focus_date: `${ymd(daysAgo(1))} 11:20:00`,
    url: 'https://news.cctv.com/2026/09/22/ARTI4.shtml'
  },
  {
    id: 'A5',
    title: '秋日风光摄影图集',
    brief: '多地进入秋季观赏期，摄影师记录下斑斓色彩。',
    keywords: '图集',
    focus_date: `${ymd(daysAgo(0))} 08:00:00`,
    url: 'https://photo.cctv.com/2026/09/23/PHOA5.shtml'
  }
];

const govHtml = `<!doctype html>
<html><body>
  <ul class="list">
    <li><a href="./202609/t20260922_1001.shtml">国务院办公厅关于促进消费的若干措施</a></li>
    <li><a href="./202609/t20260923_1002.shtml">关于加快推进制造业产业链升级的通知</a></li>
    <li><a href="/zhengce/content/202609/t20260923_1003.shtml">扎实推进乡村建设行动实施方案</a></li>
    <li><a href="./about.shtml">站点地图</a></li>
  </ul>
</body></html>
`;

// 人民日报观点频道样本：链接形如 /n1/2026/0923/c461529-40803815.html（日期只藏在链接里）
const peopleDate = (() => {
  const date = daysAgo(0);
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getUTCFullYear()}/${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}`;
})();

const peopleHtml = `<!doctype html>
<html><body>
  <div class="hdNews clearfix"><p>
    <strong><a href='/n1/${peopleDate}/c461529-40803815.html' target="_blank">人民锐评：把民生实事办到群众心坎上</a></strong>
    <em class="gray2"><a href='/n1/${peopleDate}/c461529-40803815.html' target="_blank">今年以来各地持续推进民生实事项目，把群众身边的小事当作大事来办，让发展成果更多更公平惠及全体人民，群众的获得感成色更足。</a></em>
  </p></div>
  <div class="hdNews clearfix"><p>
    <strong><a href='/n1/${peopleDate}/c461529-40803816.html' target="_blank">今日谈：让乡村振兴的产业根基更扎实</a></strong>
    <em class="gray2"><a href='/n1/${peopleDate}/c461529-40803816.html' target="_blank">产业振兴是乡村振兴的重中之重，要因地制宜发展特色产业，完善联农带农机制。</a></em>
  </p></div>
  <div class="hdNews clearfix"><p>
    <strong><a href='/n1/${peopleDate}/c461529-40803817.html' target="_blank">仲音：以科技创新引领新质生产力发展</a></strong>
    <em class="gray2"><a href='/n1/${peopleDate}/c461529-40803817.html' target="_blank">科技创新是发展新质生产力的核心要素，要打通科技成果转化通道。</a></em>
  </p></div>
  <a href="/GB/8213/49160/index.html">人民日报要论</a>
</body></html>
`;

// 中国政府网政策文件库样本：字段有 title / url / pubtimeStr（2026.09.18）/ subjectword
const dotDate = (days) => ymd(daysAgo(days)).replace(/-/g, '.');
const govApiItems = [
  {
    title: '国务院办公厅关于促进服务消费高质量发展的意见',
    url: 'https://www.gov.cn/zhengce/content/202609/content_7081611.htm',
    pubtimeStr: dotDate(0),
    summary: '围绕餐饮、文旅、体育等重点领域提出若干措施，扩大优质服务供给。',
    subjectword: '服务消费 消费'
  },
  {
    title: '国务院办公厅转发关于促进房车消费的若干措施的通知',
    url: 'https://www.gov.cn/zhengce/content/202609/content_7081612.htm',
    pubtimeStr: dotDate(1),
    summary: '提出完善营地设施、优化金融服务等举措，释放消费潜力。',
    subjectword: '消费'
  },
  {
    title: '市场监督管理所条例',
    url: 'https://www.gov.cn/zhengce/content/202609/content_7081613.htm',
    pubtimeStr: dotDate(2),
    summary: '健全基层市场监管体系，明确执法职责。',
    subjectword: '法治 市场监管'
  }
];

fs.writeFileSync(path.join(tmp, 'policy.xml'), rss(policyItems), 'utf8');
fs.writeFileSync(path.join(tmp, 'news.xml'), rss(newsItems), 'utf8');
fs.writeFileSync(path.join(tmp, 'stale.xml'), rss(staleItems, { withDate: false }), 'utf8');
fs.writeFileSync(path.join(tmp, 'gov.html'), govHtml, 'utf8');
fs.writeFileSync(path.join(tmp, 'cctv.jsonp'), `news(${JSON.stringify({ data: { list: cctvItems } })})`, 'utf8');
fs.writeFileSync(path.join(tmp, 'people.html'), peopleHtml, 'utf8');
fs.writeFileSync(path.join(tmp, 'gov.json'), JSON.stringify({ searchVO: { listVO: govApiItems } }), 'utf8');

const categories = {
  '政治': ['习近平', '中央', '国务院', '政治局', '全会', '全国人大', '政协', '重要讲话', '决策部署', '党组', '纪委', '党建'],
  '经济': ['经济', '财政', '货币政策', '金融', 'GDP', '消费', '投资', '外贸', '出口', '税收', '就业', '产业链', '制造业', '民营经济', '稳增长'],
  '民生': ['民生', '社保', '医保', '养老', '住房', '食品安全', '物价', '医疗', '救助', '供水', '供电', '供暖'],
  '法治': ['法治', '法律', '立法', '司法', '检察', '监察', '条例', '修订', '依法办事', '行政法规'],
  '科技': ['科技', '创新', '人工智能', '芯片', '航天', '量子', '生物医药', '新能源', '算力', '5G', '重大专项'],
  '生态': ['生态', '环保', '碳达峰', '碳中和', '绿色', '污染', '长江', '黄河', '能源保供'],
  '文化': ['文化', '文明', '遗产', '非遗', '旅游', '出版', '教育', '思政', '高考'],
  '外交': ['外交', '外长', '峰会', '双边', '会晤', '联合国', '一带一路', '自贸', '全球治理', '上合'],
  '乡村': ['乡村振兴', '三农', '粮食', '农业', '农村', '耕地', '脱贫', '种植'],
  '评论': ['评论', '锐评', '时评', '网评', '短评', '今日谈', '声音', '观察', '漫评', '青平', '任平', '仲音']
};

const config = {
  max_items: 10,
  min_items: 5,
  publish_floor: 3,
  max_age_days: 4,
  selection: {
    max_per_source: 4,
    max_per_kind: { policy: 3, comment: 4 }
  },
  kind_bonus: { policy: 3, comment: 0, news: 0 },
  penalties: ['直播', '图集', '图说', '视频', '花絮', '广告', '招聘', '预告', '海报'],
  url_penalties: ['photo.', '/photo/'],
  categories,
  sources: [
    { name: '样本 · 政策', type: 'rss', url: 'https://example.gov.cn/policy.xml', fixture: 'policy.xml', kind: 'policy', weight: 3 },
    { name: '样本 · 新闻', type: 'rss', url: 'https://example.gov.cn/news.xml', fixture: 'news.xml', kind: 'news', weight: 2 },
    { name: '样本 · 政策列表页', type: 'html_links', url: 'https://www.gov.cn/zhengce/zuixin/', include: '\\.(shtml|html)$', fixture: 'gov.html', kind: 'policy', weight: 3 },
    {
      name: '样本 · 央视接口',
      type: 'json',
      url: 'https://news.cctv.com/api.jsonp',
      fixture: 'cctv.jsonp',
      list_path: 'data.list',
      title_field: 'title',
      url_field: 'url',
      date_field: 'focus_date',
      summary_field: 'brief',
      keywords_field: 'keywords',
      kind: 'news',
      weight: 3
    },
    {
      name: '样本 · 政策接口',
      type: 'json',
      url: 'https://sousuo.www.gov.cn/search-gov/data',
      fixture: 'gov.json',
      list_path: 'searchVO.listVO',
      title_field: 'title',
      url_field: 'url',
      date_field: 'pubtimeStr',
      summary_field: 'summary',
      keywords_field: 'subjectword',
      kind: 'policy',
      weight: 3
    },
    {
      name: '样本 · 评论频道',
      type: 'html_links',
      url: 'http://opinion.people.com.cn/',
      include: '\\.html$',
      fixture: 'people.html',
      kind: 'comment',
      weight: 3
    },
    { name: '样本 · 僵尸RSS', type: 'rss', url: 'https://www.news.cn/stale.xml', fixture: 'stale.xml', kind: 'news', weight: 3 }
  ]
};

const configPath = path.join(tmp, 'config.json');
fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf8');

console.log('1) 生成器离线运行');
const outDir = path.join(tmp, 'out');
const run = spawnSync(process.execPath, [
  path.join(here, 'build_digest.mjs'),
  '--config', configPath,
  '--fixture-dir', tmp,
  '--out-dir', outDir,
  '--today', '2026-09-23'
], { encoding: 'utf8', cwd: root });

if (run.stdout) console.log(run.stdout.trim().split('\n').map((line) => `     ${line}`).join('\n'));
if (run.stderr) console.log(run.stderr.trim().split('\n').map((line) => `     ${line}`).join('\n'));
check('生成器退出码为 0', run.status === 0, `status=${run.status}`);

console.log('2) 检查输出文件');
const latestPath = path.join(outDir, 'digest-latest.json');
const datedPath = path.join(outDir, 'digest-2026-09-23.json');
const indexPath = path.join(outDir, 'index.json');
check('生成 digest-latest.json', fs.existsSync(latestPath));
check('生成按日期的文件', fs.existsSync(datedPath));
check('生成 index.json', fs.existsSync(indexPath));

const digest = JSON.parse(fs.readFileSync(latestPath, 'utf8'));
const titles = digest.items.map((item) => item.title).join('|');
const allSummaries = digest.items.map((item) => item.summary).join('|');

console.log('3) 检查内容质量');
check('条数在 5~10 之间', digest.items.length >= 5 && digest.items.length <= 10, `实际 ${digest.items.length}`);
check('未标记 degraded', digest.degraded === false);
check('每条都有标题与来源', digest.items.every((item) => item.title && item.source));
check('每条都有 id 且唯一', new Set(digest.items.map((item) => item.id)).size === digest.items.length);
check('每条都有分类', digest.items.every((item) => item.category && item.category.length > 0));
check('每条都有链接', digest.items.every((item) => item.link && item.link.startsWith('http')));
check('每条都有日期', digest.items.every((item) => typeof item.published === 'string' && item.published.length > 0));
check('没有相对链接漏出来', digest.items.every((item) => /^https?:\/\//.test(item.link)));
check('娱乐类噪音被筛掉', !titles.includes('美食节') && !titles.includes('足球邀请赛'));
check('包含政策类高相关条目', titles.includes('国务院常务会议') || titles.includes('中央政治局会议'));
check('生成方式是抽取式', digest.method === 'extractive');
check('日期正确', digest.date === '2026-09-23');
check('generatedAt 是 ISO 秒级格式', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(digest.generatedAt), digest.generatedAt);
check('央视接口的摘要被采用', allSummaries.includes('扩大国内需求'));
check('央视接口的关键词变成考点标签', digest.items.some((item) => {
  const tags = item.tags || [];
  return tags.includes('扩大内需') || tags.includes('消费') || tags.includes('民营经济');
}));
check('图片类条目被降权或排除', !titles.includes('秋日风光摄影图集'));

console.log('4) 检查僵尸源、接口字段与日期兜底');
check('来源状态有 7 条', Array.isArray(digest.sources) && digest.sources.length === 7);
const staleStatus = digest.sources.find((source) => source.name === '样本 · 僵尸RSS');
check('僵尸源被标记为失败', staleStatus && staleStatus.ok === false, JSON.stringify(staleStatus));
check('僵尸源给出原因', staleStatus && /超过 4 天|没有日期/.test(staleStatus.note || ''), staleStatus && staleStatus.note);
check('僵尸源旧闻没有混进结果', !titles.includes('2022年'));
const htmlStatus = digest.sources.find((source) => source.name === '样本 · 政策列表页');
check('列表页成功解析 3 条（无日期的导航链接被跳过）', htmlStatus && htmlStatus.count === 3, JSON.stringify(htmlStatus));
const govApiStatus = digest.sources.find((source) => source.name === '样本 · 政策接口');
check('政策接口（pubtimeStr 带点）日期解析成功', govApiStatus && govApiStatus.ok === true && govApiStatus.count === 3, JSON.stringify(govApiStatus));
const peopleStatus = digest.sources.find((source) => source.name === '样本 · 评论频道');
check('人民网风格链接（/年/月日/）日期解析成功', peopleStatus && peopleStatus.ok === true && peopleStatus.count === 3, JSON.stringify(peopleStatus));
check('成功来源有 6 个', digest.sources.filter((source) => source.ok).length === 6);
const kindOf = (name) => (config.sources.find((source) => source.name === name) || {}).kind;
const commentCount = digest.items.filter((item) => kindOf(item.source) === 'comment').length;
const policyCount = digest.items.filter((item) => kindOf(item.source) === 'policy').length;
const maxPerSource = Math.max(...Object.values(digest.items.reduce((accumulator, item) => {
  accumulator[item.source] = (accumulator[item.source] || 0) + 1;
  return accumulator;
}, {})));
check('评论类不超过 4 条', commentCount <= 4, `实际 ${commentCount}`);
check('政策类不超过 3 条', policyCount <= 3, `实际 ${policyCount}`);
check('同一来源不超过 4 条', maxPerSource <= 4, `实际 ${maxPerSource}`);

console.log('   本次选出的要点：');
digest.items.forEach((item, index) => {
  console.log(`     ${String(index + 1).padStart(2)}. [${item.category}] ${item.title}`);
});

console.log('5) 检查双锚文本页面（标题 vs 摘要）');
const peopleOnlyConfig = {
  ...config,
  sources: [config.sources.find((source) => source.name === '样本 · 评论频道')]
};
const peopleOnlyPath = path.join(tmp, 'people-config.json');
fs.writeFileSync(peopleOnlyPath, JSON.stringify(peopleOnlyConfig, null, 2), 'utf8');
const peopleRun = spawnSync(process.execPath, [
  path.join(here, 'build_digest.mjs'),
  '--config', peopleOnlyPath,
  '--fixture-dir', tmp,
  '--out-dir', path.join(tmp, 'out-people'),
  '--today', '2026-09-23'
], { encoding: 'utf8', cwd: root });
const peopleDigest = fs.existsSync(path.join(tmp, 'out-people', 'digest-latest.json'))
  ? JSON.parse(fs.readFileSync(path.join(tmp, 'out-people', 'digest-latest.json'), 'utf8'))
  : { items: [] };
check('评论频道单独运行时可用', peopleRun.status === 0, `status=${peopleRun.status}`);
check('标题取的是 <strong> 里的短标题', peopleDigest.items.some((item) => item.title === '人民锐评：把民生实事办到群众心坎上'), JSON.stringify(peopleDigest.items.map((item) => item.title)));
check('摘要取的是 <em> 里的长文本', peopleDigest.items.some((item) => item.summary.includes('民生实事项目')));
check('所有标题都在可读长度内', peopleDigest.items.every((item) => item.title.length <= 60), JSON.stringify(peopleDigest.items.map((item) => item.title.length)));

console.log('6) 检查去重与候选不足的保护');
const nearDuplicateItems = [
  {
    title: '国务院常务会议部署稳就业稳经济措施',
    link: 'https://example.gov.cn/dup-1.shtml',
    summary: '重复条目的近似版本',
    date: daysAgo(0)
  },
  {
    title: '国务院常务会议部署稳就业稳经济措施！',
    link: 'https://example.gov.cn/dup-2.shtml',
    summary: '带标点的重复条目',
    date: daysAgo(0)
  }
];
fs.writeFileSync(path.join(tmp, 'dup.xml'), rss(nearDuplicateItems), 'utf8');
const dupConfig = {
  ...config,
  sources: [{ name: '样本 · 去重', type: 'rss', url: 'https://example.gov.cn/dup.xml', fixture: 'dup.xml', weight: 3 }]
};
const dupConfigPath = path.join(tmp, 'dup-config.json');
fs.writeFileSync(dupConfigPath, JSON.stringify(dupConfig, null, 2), 'utf8');
const dupRun = spawnSync(process.execPath, [
  path.join(here, 'build_digest.mjs'),
  '--config', dupConfigPath,
  '--fixture-dir', tmp,
  '--out-dir', path.join(tmp, 'out-dup'),
  '--today', '2026-09-23'
], { encoding: 'utf8', cwd: root });
check('近似重复只剩 1 条，低于下限时按预期失败', dupRun.status !== 0, `status=${dupRun.status}`);
check('候选不足时不写入 latest', !fs.existsSync(path.join(tmp, 'out-dup', 'digest-latest.json')));

console.log('');
if (failures.length === 0) {
  console.log('全部通过 ✅');
} else {
  console.log(`失败 ${failures.length} 项 ❌：${failures.join('、')}`);
  process.exitCode = 1;
}
fs.rmSync(tmp, { recursive: true, force: true });
