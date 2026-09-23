#!/usr/bin/env node
// 国考每日时政要点生成器（Node 18+，零依赖）
//
// 用法：
//   node tools/build_digest.mjs                                  正常联网抓取
//   node tools/build_digest.mjs --fixture-dir tools/fixtures     离线跑，用本地样本
//   node tools/build_digest.mjs --today 2026-09-23 --out-dir out 指定日期与输出目录
//
// 可选的大模型精炼（不配置就跳过，用抽取式摘要）：
//   DIGEST_LLM_KEY   接口密钥
//   DIGEST_LLM_BASE  接口地址，默认 https://api.deepseek.com/v1（任何 OpenAI 兼容接口都行）
//   DIGEST_LLM_MODEL 模型名，默认 deepseek-chat

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const USAGE = `
用法: node tools/build_digest.mjs [选项]
  --out-dir <dir>      输出目录，默认 data
  --config <file>      来源配置，默认 tools/sources.json
  --fixture-dir <dir>  离线模式：从该目录读取样本文件，不联网
  --today <yyyy-mm-dd> 指定"今天"（北京时间），默认取当前时间
  --no-llm             强制跳过联网大模型精炼
  --help               显示帮助
`.trim();

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const HTTP_TIMEOUT_MS = 20000;
const RETRIES = 2;

function log(message) {
  console.log(`[digest] ${message}`);
}

function parseArgs(argv) {
  const args = {
    outDir: 'data',
    config: 'tools/sources.json',
    fixtureDir: null,
    today: null,
    noLlm: false
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--out-dir') args.outDir = argv[++i];
    else if (arg === '--config') args.config = argv[++i];
    else if (arg === '--fixture-dir') args.fixtureDir = argv[++i];
    else if (arg === '--today') args.today = argv[++i];
    else if (arg === '--no-llm') args.noLlm = true;
    else if (arg === '--probe-url') args.probeUrl = argv[++i];
    else if (arg === '--help' || arg === '-h') {
      console.log(USAGE);
      process.exit(0);
    } else {
      throw new Error(`未知参数：${arg}`);
    }
  }
  return args;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------- 通用工具 ----------

function stripCdata(text) {
  return String(text || '').replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1');
}

function stripTags(text) {
  return stripCdata(text)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ');
}

function decodeEntities(text) {
  const named = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&middot;': '·',
    '&mdash;': '—'
  };
  let output = String(text || '');
  for (const [key, value] of Object.entries(named)) {
    output = output.split(key).join(value);
  }
  output = output.replace(/&#x([0-9a-f]+);/gi, (_, hex) => {
    const code = Number.parseInt(hex, 16);
    return Number.isFinite(code) ? String.fromCodePoint(code) : '';
  });
  output = output.replace(/&#(\d+);/g, (_, dec) => {
    const code = Number.parseInt(dec, 10);
    return Number.isFinite(code) ? String.fromCodePoint(code) : '';
  });
  return output;
}

function cleanText(raw, limit = 220) {
  const text = decodeEntities(stripTags(raw)).replace(/\s+/g, ' ').trim();
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

function normalizeTitle(title) {
  return decodeEntities(stripTags(title))
    .replace(/[\s\u3000]/g, '')
    .replace(/[，。、；：！？“”"'（）()《》〈〉·\-,.?!:;<>\[\]【】—…]/g, '')
    .trim();
}

function trigramSimilarity(a, b) {
  const build = (value) => {
    const set = new Set();
    for (let i = 0; i + 3 <= value.length; i += 1) set.add(value.slice(i, i + 3));
    return set;
  };
  if (a.length < 3 || b.length < 3) return a === b ? 1 : 0;
  const setA = build(a);
  const setB = build(b);
  let shared = 0;
  for (const gram of setA) if (setB.has(gram)) shared += 1;
  return shared / (setA.size + setB.size - shared);
}

function itemId(item) {
  const basis = item.link && item.link.length > 0 ? item.link : `${item.source}|${item.title}`;
  return crypto.createHash('sha1').update(basis).digest('hex').slice(0, 16);
}

function toIsoSeconds(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function beijingToday(override) {
  if (override) return override;
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  return now.toISOString().slice(0, 10);
}

// ---------- 抓取 ----------

async function fetchText(url, extraHeaders = {}) {
  let lastError = null;
  for (let attempt = 0; attempt <= RETRIES; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        redirect: 'follow',
        signal: controller.signal,
        headers: {
          'User-Agent': UA,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
          ...extraHeaders
        }
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return await response.text();
    } catch (error) {
      lastError = error;
      if (attempt < RETRIES) await sleep(900 * (attempt + 1));
    } finally {
      clearTimeout(timer);
    }
  }
  throw lastError || new Error('抓取失败');
}

async function loadSourceBody(source, args, page) {
  if (args.fixtureDir) {
    if (!source.fixture) return null;
    const file = path.join(args.fixtureDir, source.fixture);
    if (!fs.existsSync(file)) throw new Error(`样本文件不存在：${file}`);
    return fs.readFileSync(file, 'utf8');
  }
  let url = source.url;
  if (page && source.page_param) {
    const parsed = new URL(source.url);
    parsed.searchParams.set(source.page_param, String(page));
    url = parsed.toString();
  }
  return await fetchText(url, source.headers || {});
}

// ---------- 解析 ----------

/// 从链接里猜日期。很多站点的列表页不带时间，但 URL 里有（202609/t20260922_…）。
function urlDate(text) {
  if (!text) return null;
  const patterns = [
    /(20\d{2})[-_/](\d{1,2})[-_/](\d{1,2})/,
    /t(20\d{2})(\d{2})(\d{2})_/,
    /\/(20\d{2})(\d{2})(\d{2})\//,
    // 人民网风格：/n1/2026/0923/c461529-40803815.html
    /\/(20\d{2})\/(\d{2})(\d{2})\//
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) {
      const year = Number.parseInt(match[1], 10);
      const month = Number.parseInt(match[2], 10);
      const day = Number.parseInt(match[3], 10);
      if (year >= 2015 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return `${match[1]}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      }
    }
  }
  return null;
}

function pickTag(block, names) {
  for (const name of names) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = block.match(new RegExp(`<${escaped}\\b[^>]*>([\\s\\S]*?)<\\/${escaped}>`, 'i'));
    if (match && match[1]) return match[1];
  }
  return '';
}

/// 返回 { items, note }；note 用于把这些情况写进来源状态，方便排查。
function parseFeed(xml, source) {
  const items = [];
  const seen = new Set();
  for (const tag of ['item', 'entry']) {
    const regex = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi');
    let match = regex.exec(xml);
    while (match) {
      const block = match[1];
      const title = cleanText(pickTag(block, ['title']), 120);
      let link = cleanText(pickTag(block, ['link']), 300);
      if (!link || link.startsWith('<')) {
        const href = block.match(/<link[^>]*href=["']([^"']+)["']/i);
        link = href ? href[1].trim() : '';
      }
      const dateRaw = cleanText(pickTag(block, ['pubDate', 'published', 'updated', 'dc:date', 'date']), 60);
      const summary = cleanText(pickTag(block, ['description', 'summary', 'content:encoded', 'content']), 220);
      if (title.length >= 6 && !seen.has(normalizeTitle(title))) {
        seen.add(normalizeTitle(title));
        // 有些 RSS（例如新华网那份）不带 pubDate，正文里全是旧闻，只能靠链接里的日期判断。
        const published = parseDate(dateRaw) || parseDate(urlDate(link));
        items.push({
          title,
          link,
          summary,
          published,
          source: source.name
        });
      }
      match = regex.exec(xml);
    }
    if (items.length > 0) break;
  }
  const undated = items.filter((item) => !item.published).length;
  return {
    items,
    note: undated > 0 ? `${undated} 条没有日期（已降权）` : null
  };
}

function parseHtmlLinks(html, source) {
  const include = source.include ? new RegExp(source.include, 'i') : null;
  const regex = /<a\s[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  const groups = new Map();
  let undatedSkipped = 0;
  let match = regex.exec(html);
  while (match !== null) {
    const href = match[1].trim();
    const rawTitle = match[2];
    const preceding = html.slice(Math.max(0, match.index - 48), match.index);
    match = regex.exec(html);
    if (include && !include.test(href)) continue;
    const text = cleanText(rawTitle, 400);
    if (text.length < 8 || normalizeTitle(text).startsWith('http')) continue;
    let absolute = href;
    try {
      absolute = new URL(href, source.url).toString();
    } catch {
      absolute = href;
    }
    // 去掉 #liuyan 之类的锚点，保证同一篇文章归到一组
    absolute = absolute.split('#')[0];
    // 列表页没有时间字段，只能从链接里提取；提取不到的多半是栏目导航，直接跳过。
    const published = parseDate(urlDate(absolute));
    if (!published) {
      undatedSkipped += 1;
      continue;
    }
    // 标题通常包在 <strong>/<h1-6> 里，摘要则是不带强调的长文本
    const emphasis = /<(strong|h[1-6]|b)[^>]*>\s*$/i.test(preceding);
    const group = groups.get(absolute);
    if (group) {
      group.candidates.push({ text, emphasis });
    } else {
      groups.set(absolute, { published, candidates: [{ text, emphasis }] });
    }
  }

  const items = [];
  const seen = new Set();
  for (const [link, group] of groups) {
    const byLength = [...group.candidates].sort((a, b) => a.text.length - b.text.length);
    const emphasized = group.candidates
      .filter((candidate) => candidate.emphasis)
      .sort((a, b) => a.text.length - b.text.length);
    const titleCandidate = emphasized[0] ?? byLength[0];
    const title = shortenTitle(titleCandidate.text, 60);
    const longest = [...group.candidates].sort((a, b) => b.text.length - a.text.length)[0];
    let summary = '';
    if (longest && longest.text !== titleCandidate.text && longest.text.length > 20) {
      summary = longest.text.length > 220 ? `${longest.text.slice(0, 219)}…` : longest.text;
    }
    const key = normalizeTitle(title);
    if (title.length < 8 || seen.has(key)) continue;
    seen.add(key);
    items.push({
      title,
      link,
      summary,
      published: group.published,
      source: source.name
    });
  }
  return {
    items,
    note: undatedSkipped > 0 ? `跳过 ${undatedSkipped} 个没有日期的链接` : null
  };
}

/// 有些列表页把整段正文当标题，按标点截到可读长度。
function shortenTitle(text, max) {
  if (text.length <= max) return text;
  const head = text.slice(0, max);
  const cut = Math.max(
    head.lastIndexOf('。'),
    head.lastIndexOf('！'),
    head.lastIndexOf('？'),
    head.lastIndexOf('；'),
    head.lastIndexOf('，')
  );
  if (cut >= 10) return head.slice(0, cut);
  return head;
}

/// 短评风格：只留第一句话，并控制在 max 字以内。
function firstSentence(text, max) {
  const clean = String(text || '').replace(/\s+/g, ' ').trim();
  if (!clean) return '';
  const match = clean.match(/^[^。！？!?]{6,}?[。！？!?]/);
  let sentence = (match ? match[0] : clean).trim();
  if (sentence.length > max) {
    // 优先在逗号/分号处断开，避免截到半个词
    const head = sentence.slice(0, max);
    const cut = Math.max(head.lastIndexOf('，'), head.lastIndexOf('；'), head.lastIndexOf('、'));
    sentence = cut >= 12 ? `${head.slice(0, cut)}。` : `${head.slice(0, max - 1)}…`;
  }
  return sentence;
}

// ---------- 正文提取（供 App 内直接阅读，不跳网页） ----------

const BOILERPLATE = /(责任编辑|来源[:：]|声明|版权|免责|扫码|关注微信|微信公众号|上一页|下一页|相关阅读|热门推荐|编辑[:：]|转载|纠错|返回顶部|分享到|打印本页|关闭窗口|广告|原标题|【编辑|点击进入|更多精彩|频道导航|网站地图|关于我们|联系方式|京ICP|举报)/;

/// 从新闻页 HTML 里抽正文段落：优先常见正文容器，抽不到就退回全文的 <p>。
function extractArticleText(html, maxChars = 1200) {
  let scope = html;
  const containerPatterns = [
    /<div[^>]*(?:class|id)=["'][^"']*(?:article|content|main|text|detail|body|conTxt|TRS_Editor)[^"']*["'][^>]*>([\s\S]*?)<\/div>/i,
    /<article[^>]*>([\s\S]*?)<\/article>/i
  ];
  for (const pattern of containerPatterns) {
    const match = html.match(pattern);
    if (match && match[1] && match[1].length > 400) {
      scope = match[1];
      break;
    }
  }

  const cleaned = scope
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<(nav|header|footer|aside|form|iframe)[\s\S]*?<\/\1>/gi, ' ');

  const paragraphs = collectParagraphs(cleaned);

  // 有些站点（比如央视）把正文放在 JS 字符串里：var contentdate = '<p>…</p>'
  if (paragraphs.length < 2) {
    const jsMatch = html.match(/(?:var\s+)?(?:contentdate|articleContent|content_html|newsContent)\s*=\s*['"]((?:[^'"\\]|\\.){200,}?)['"]\s*[;\n]/i);
    if (jsMatch) {
      const unescaped = jsMatch[1]
        .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(Number.parseInt(hex, 16)))
        .replace(/\\'/g, "'")
        .replace(/\\"/g, '"')
        .replace(/\\\//g, '/')
        .replace(/\\r?\\n/g, '\n');
      for (const paragraph of collectParagraphs(unescaped)) {
        if (!paragraphs.includes(paragraph)) paragraphs.push(paragraph);
      }
    }
  }

  // 段落太少时，退一步用整页文本切句
  if (paragraphs.length < 2) {
    const whole = cleanText(cleaned, 6000);
    const sentences = whole.split(/(?<=[。！？])/).map((part) => part.trim()).filter((part) => part.length >= 18 && !BOILERPLATE.test(part));
    for (const sentence of sentences) {
      if (paragraphs.length >= 12) break;
      paragraphs.push(sentence);
    }
  }

  const kept = [];
  let total = 0;
  for (const paragraph of paragraphs) {
    if (total >= maxChars) break;
    kept.push(paragraph);
    total += paragraph.length;
  }
  return kept.join('\n');
}

/// 从一段 HTML 里收集可读段落。
function collectParagraphs(html) {
  const paragraphs = [];
  const regex = /<p[^>]*>([\s\S]*?)<\/p>/gi;
  let match = regex.exec(html);
  while (match !== null) {
    const text = cleanText(match[1], 600).trim();
    match = regex.exec(html);
    if (text.length < 18) continue;
    if (BOILERPLATE.test(text)) continue;
    if (/^[\d\s.、]+$/.test(text)) continue;
    if (paragraphs.length > 0 && paragraphs[paragraphs.length - 1] === text) continue;
    paragraphs.push(text);
  }
  return paragraphs;
}

/// 判断一段摘要是不是"不能当短评用"的噪声：
/// 发文字号、公众号导语、空话开头、跟标题重复的，都直接丢掉，只留标题。
function isWeakSummary(summary, title) {
  const text = String(summary || '').trim();
  if (text.length < 12) return true;
  const normSummary = normalizeTitle(text);
  const normTitle = normalizeTitle(title);
  if (!normSummary) return true;
  if (normTitle.length > 8 && (normSummary.includes(normTitle) || normTitle.includes(normSummary))) return true;
  if (/^(当前|近年来|近期|如今)[，,]/.test(text)) return true;
  if (/据[^，。；]{0,16}(公众号|微博|客户端|消息|报道)/.test(text)) return true;
  if (/(国办函|国发〔|国办发〔|号）|印发的通知)/.test(text)) return true;
  if (/^[\u4e00-\u9fa5]{2,12}(办公厅|部门|委员会|总局)\s*(关于|转发|印发)/.test(text)) return true;
  // 抒情、应景式开头（飘香、渐近之类）不是每日时政的语气，丢掉摘要只留标题
  if (/(飘香|渐近|渐浓|秋月|金秋|稻谷|瓜果|佳节|团圆|花开|春意)/.test(text)) return true;
  // 又短、又没有数字、也没有动作词，基本是空话
  const hasNumber = /\d/.test(text);
  const hasAction = /(部署|印发|发布|通过|签署|增长|下降|达到|宣布|启动|完成|实现|要求|明确|提出|决定|数据|预计|突破|新增|同比|会议|规划|推进|开展|出台|实施|举行|召开|表示|介绍)/.test(text);
  if (!hasNumber && !hasAction && text.length < 30) return true;
  return false;
}

/// 从正文里挑一句最适合当「每日时政」简报的话：跳过抒情开头、公众号导语这类句子。
function bestBriefSentence(text, max) {
  const clean = String(text || '').replace(/\n/g, ' ').replace(/\s+/g, ' ').trim();
  if (!clean) return '';
  const sentences = clean.match(/[^。！？!?]+[。！？!?]?/g) || [];
  for (const sentence of sentences.slice(0, 8)) {
    const trimmed = sentence.trim();
    if (trimmed.length < 18) continue;
    if (isWeakSummary(trimmed, '')) continue;
    const brief = firstSentence(trimmed, max);
    if (brief.length >= 18) return brief;
  }
  return '';
}

/// 通用 JSON / JSONP 列表接口解析：列表路径和字段名都在配置里指定。
/// 例如央视新闻接口（data.list，自带 brief 与 keywords）和中国政府网政策文件库（searchVO.listVO）。
function parseJson(body, source) {
  const match = body.match(/\{[\s\S]*\}/);
  if (!match) return { items: [], note: '返回内容里没有 JSON' };
  let parsed;
  try {
    parsed = JSON.parse(match[0]);
  } catch (error) {
    return { items: [], note: `JSON 解析失败：${error.message}` };
  }

  const listPath = String(source.list_path || 'data.list');
  let node = parsed;
  for (const key of listPath.split('.').filter(Boolean)) {
    node = node && typeof node === 'object' ? node[key] : null;
  }
  if (!Array.isArray(node)) return { items: [], note: `JSON 里找不到列表（${listPath}）` };

  const titleField = source.title_field || 'title';
  const urlField = source.url_field || 'url';
  const dateField = source.date_field || 'date';
  const summaryField = source.summary_field || 'summary';
  const keywordsField = source.keywords_field || '';
  const items = [];
  const seen = new Set();
  for (const entry of node) {
    const title = cleanText(entry?.[titleField], 120);
    if (title.length < 6) continue;
    const key = normalizeTitle(title);
    if (seen.has(key)) continue;
    let link = String(entry?.[urlField] ?? '').trim();
    if (link.startsWith('/')) {
      try {
        link = new URL(link, source.url).toString();
      } catch {
        // 保留原样
      }
    }
    seen.add(key);
    items.push({
      title,
      link,
      summary: cleanText(entry?.[summaryField], 220),
      keywords: keywordsField ? cleanText(entry?.[keywordsField], 60) : '',
      published: parseDate(String(entry?.[dateField] ?? '')) || parseDate(urlDate(link)),
      source: source.name
    });
  }
  return { items, note: null };
}

/// 解析页面里内嵌的 JSON 对象数组（例如央视评论频道把列表放在 var obj = [{...}] 里）。
/// pattern 与字段名都写在 sources.json 里，加同类站点不用改代码。
function parseEmbeddedObjects(html, source) {
  if (!source.pattern) return { items: [], note: '缺少 pattern 配置' };
  const fields = source.fields || ['url', 'title', 'brief', 'author', 'date'];
  const regex = new RegExp(source.pattern, 'gi');
  const items = [];
  const seen = new Set();
  let match = regex.exec(html);
  while (match !== null) {
    const row = {};
    fields.forEach((field, index) => {
      row[field] = match[index + 1] ? cleanText(match[index + 1], 200) : '';
    });
    match = regex.exec(html);

    const title = row.title || '';
    if (title.length < 6) continue;
    const key = normalizeTitle(title);
    if (seen.has(key)) continue;
    seen.add(key);

    let link = (row.url || '').trim();
    if (link.startsWith('//')) link = `https:${link}`;
    items.push({
      title,
      link,
      summary: row.brief || '',
      keywords: row.author || '',
      published: parseDate(row.date || '') || parseDate(urlDate(link)),
      source: source.name
    });
  }
  return { items, note: null };
}

function parseDate(raw) {
  if (!raw) return null;
  const text = String(raw).trim();
  if (!text) return null;
  // 央视评论用的写法：2026年09月11日
  const chinese = text.match(/^(20\d{2})年(\d{1,2})月(\d{1,2})日/);
  if (chinese) {
    return parseDate(`${chinese[1]}-${String(chinese[2]).padStart(2, '0')}-${String(chinese[3]).padStart(2, '0')}`);
  }
  // 统一成 2026-09-18，兼容 2026.09.18 / 2026/9/18 这类写法
  const normalized = text.replace(/^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})/, (_, year, month, day) =>
    `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`);
  const candidates = [normalized];
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(normalized)) {
    candidates.unshift(normalized.replace(' ', 'T') + '+08:00');
  } else if (/^\d{4}-\d{2}-\d{2}$/.test(normalized)) {
    candidates.unshift(normalized + 'T00:00:00+08:00');
  }
  for (const candidate of candidates) {
    const parsed = new Date(candidate);
    if (!Number.isNaN(parsed.getTime())) return parsed;
  }
  return null;
}

// ---------- 打分与筛选 ----------

function scoreItem(item, config, now) {
  const haystack = `${item.title} ${item.summary}`;
  let keywordScore = 0;
  const categories = [];
  for (const [category, words] of Object.entries(config.categories || {})) {
    let hits = 0;
    for (const word of words) if (haystack.includes(word)) hits += 1;
    if (hits > 0) {
      categories.push({ category, hits });
      keywordScore += Math.min(hits, 3);
    }
  }
  categories.sort((a, b) => b.hits - a.hits);

  let penalty = 0;
  for (const word of config.penalties || []) if (haystack.includes(word)) penalty += 3;
  for (const word of config.url_penalties || []) {
    if (item.link && item.link.includes(word)) penalty += 3;
  }

  let recency = 0;
  if (item.published) {
    const ageHours = (now.getTime() - item.published.getTime()) / 3600000;
    if (ageHours <= 24) recency = 3;
    else if (ageHours <= 48) recency = 2;
    else if (ageHours <= 96) recency = 1;
    else recency = -2;
  }

  const sourceWeight = item.sourceWeight || 1;
  const kindBonus = (config.kind_bonus || {})[item.sourceKind || 'news'] ?? 0;
  const score = keywordScore * 3 + sourceWeight * 2 + recency + kindBonus - penalty;
  const keywordTags = String(item.keywords || '')
    .split(/[\s,，、;；]+/)
    .filter((word) => word.length >= 2)
    .slice(0, 2);
  // 分类放第一个，后面跟具体的考点关键词（来自接口的 keywords），最多 3 个。
  const categoryTags = categories.map((entry) => entry.category).slice(0, 1);
  return {
    ...item,
    score,
    category: categories.length > 0 ? categories[0].category : '综合',
    tags: Array.from(new Set([...categoryTags, ...keywordTags])).slice(0, 3)
  };
}

function dedupe(items) {
  const kept = [];
  for (const item of items) {
    const key = normalizeTitle(item.title);
    const duplicate = kept.some((other) => {
      const otherKey = normalizeTitle(other.title);
      if (key === otherKey) return true;
      if (key.length > 10 && otherKey.length > 10 && (key.includes(otherKey) || otherKey.includes(key))) return true;
      return trigramSimilarity(key, otherKey) >= 0.62;
    });
    if (!duplicate) kept.push(item);
  }
  return kept;
}

/// 按来源和类型做配额，避免某一天被同一个栏目（比如全是评论）刷屏。
function selectWithQuotas(ranked, config) {
  const maxItems = config.max_items ?? 10;
  const minItems = config.min_items ?? 5;
  const selection = config.selection || {};
  const maxPerSource = selection.max_per_source ?? maxItems;
  const maxPerKind = selection.max_per_kind || {};
  const picked = [];
  const sourceCount = new Map();
  const kindCount = new Map();
  const alreadyPicked = (item) => picked.some((existing) => existing.link && existing.link === item.link);

  const tryPick = (item, enforceKind) => {
    if (picked.length >= maxItems) return false;
    if (alreadyPicked(item)) return false;
    const sourceUsed = sourceCount.get(item.source) || 0;
    if (sourceUsed >= maxPerSource) return false;
    const kind = item.sourceKind || 'news';
    const kindLimit = maxPerKind[kind] ?? maxItems;
    const kindUsed = kindCount.get(kind) || 0;
    if (enforceKind && kindUsed >= kindLimit) return false;
    picked.push(item);
    sourceCount.set(item.source, sourceUsed + 1);
    kindCount.set(kind, kindUsed + 1);
    return true;
  };

  for (const item of ranked) tryPick(item, true);
  // 配额卡得太狠导致条数不够时，放宽类型限制补齐（来源上限仍然有效）
  if (picked.length < minItems) {
    for (const item of ranked) tryPick(item, false);
  }

  // 保底来源：例如央视点评这种你想每天必看的栏目，至少留一条
  const guarantees = selection.min_per_source || {};
  for (const [sourceName, minimum] of Object.entries(guarantees)) {
    let have = picked.filter((item) => item.source === sourceName).length;
    if (have >= minimum) continue;
    for (const item of ranked) {
      if (have >= minimum) break;
      if (item.source !== sourceName) continue;
      if (picked.some((existing) => existing.link && existing.link === item.link)) continue;
      if (picked.length < maxItems) {
        picked.push(item);
        have += 1;
        continue;
      }
      const replaceIndex = picked
        .map((existing, index) => ({ source: existing.source, index }))
        .filter((entry) => !guarantees[entry.source])
        .map((entry) => entry.index)
        .pop();
      if (replaceIndex === undefined) break;
      picked[replaceIndex] = item;
      have += 1;
    }
  }
  return picked;
}

// ---------- 大模型精炼（可选） ----------

function buildPrompt(candidates, maxItems, today) {
  const list = candidates
    .map((item, index) => {
      const date = item.published ? item.published.toISOString().slice(0, 10) : '日期未知';
      return `${index}. 【${item.source}｜${date}】${item.title}${item.summary ? ` — ${item.summary}` : ''}`;
    })
    .join('\n');

  return `今天是 ${today}。下面是今天抓到的时政候选条目（编号从 0 开始）：

${list}

请挑出 ${Math.min(5, maxItems)} 到 ${maxItems} 条，写成「每日时政」简报那种格式（类似粉笔每日时政）：一条一个事件，一句话讲清楚。只输出严格 JSON，不要任何解释文字：

{"items":[{"source_index":0,"title":"不超过 24 字的简讯标题","summary":"30~60 字，说清谁、在什么时间、做了什么、关键数字或影响","category":"政治/经济/民生/法治/科技/生态/文化/外交/乡村 之一","tags":["考点关键词1","考点关键词2"]}]}

要求：
1. source_index 必须来自上面的编号，不得编造新闻，不得修改事实与数字。
2. 优先选会议决策、政策文件、重要讲话、重要经济数据、民生举措；如果某条是权威媒体的评论/时评，用它的核心观点。
3. 同类事件只保留最重要的一条。
4. summary 用**新闻简讯口吻**（陈述事实，不是评论）：30~60 字，像"9月23日，工信部等三部门印发《轻工纺织产业发展"十五五"规划》，提出到2030年规上企业营收年均增长5%左右。"这样。
5. 不要分点、不要长段落、不要"具有重要意义""意义深远"这类套话，也不要照抄原文段落。
6. tags 写 2~3 个考生能记住的考点关键词（机构名、文件名、数字、主题词）。`;
}

async function refineWithLlm(candidates, options) {
  const key = process.env.DIGEST_LLM_KEY;
  if (!key || options.noLlm) return null;
  const base = (process.env.DIGEST_LLM_BASE || 'https://api.deepseek.com/v1').replace(/\/+$/, '');
  const model = process.env.DIGEST_LLM_MODEL || 'deepseek-chat';
  const url = `${base}/chat/completions`;
  const prompt = buildPrompt(candidates, options.maxItems, options.today);

  const attempt = async (withJsonMode) => {
    const body = {
      model,
      temperature: 0.2,
      messages: [
        { role: 'system', content: '你是国考时政辅导老师，擅长把当天新闻提炼成考生必须掌握的要点。只输出 JSON。' },
        { role: 'user', content: prompt }
      ]
    };
    if (withJsonMode) body.response_format = { type: 'json_object' };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 120000);
    try {
      const response = await fetch(url, {
        method: 'POST',
        signal: controller.signal,
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${key}` },
        body: JSON.stringify(body)
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      const content = payload?.choices?.[0]?.message?.content;
      if (!content) throw new Error('接口没有返回内容');
      const match = content.match(/\{[\s\S]*\}/);
      if (!match) throw new Error('返回内容里没有 JSON');
      return JSON.parse(match[0]);
    } finally {
      clearTimeout(timer);
    }
  };

  try {
    let parsed;
    try {
      parsed = await attempt(true);
    } catch (error) {
      log(`大模型 JSON 模式失败（${error.message}），改用普通模式重试`);
      parsed = await attempt(false);
    }
    const raw = Array.isArray(parsed?.items) ? parsed.items : [];
    const items = [];
    for (const entry of raw) {
      const index = Number(entry?.source_index);
      const origin = candidates[index];
      if (!origin) continue;
      const title = cleanText(entry.title, 60);
      const summary = firstSentence(cleanText(entry.summary, 240), options.summaryMax || 48);
      if (title.length < 6 || summary.length < 10) continue;
      const category = String(entry.category || '').trim() || origin.category;
      const tags = Array.isArray(entry.tags) ? entry.tags.slice(0, 3).map((tag) => cleanText(tag, 12)) : [];
      items.push({
        id: itemId(origin),
        title,
        summary,
        category,
        tags,
        source: origin.source,
        link: origin.link,
        published: origin.published ? toIsoSeconds(origin.published) : null,
        body: '',
        kind: 'news'
      });
    }
    if (items.length === 0) return null;
    log(`大模型精炼成功，得到 ${items.length} 条要点`);
    return items.slice(0, options.maxItems);
  } catch (error) {
    log(`大模型精炼失败：${error.message}，改回抽取式摘要`);
    return null;
  }
}

// ---------- 主流程 ----------

async function collect(configObject, args) {
  const now = new Date();
  const collected = [];
  const statuses = [];

  for (const source of configObject.sources || []) {
    const status = { name: source.name, ok: false, count: 0, note: null };
    // 每个来源可以有自己的时间窗口：政策文件本来就发布得稀，窗口要放宽一些。
    const maxAgeDays = source.max_age_days ?? configObject.max_age_days ?? 4;
    const maxAgeMs = maxAgeDays * 24 * 3600 * 1000;
    try {
      let items = [];
      const notes = [];
      if (source.type === 'json') {
        // JSON 接口可以翻页；离线样本模式只读第一页，保证测试可复现。
        const pageCount = args.fixtureDir ? 1 : Math.max(1, source.pages ?? 1);
        for (let page = 1; page <= pageCount; page += 1) {
          const body = await loadSourceBody(source, args, page);
          if (!body) break;
          const outcome = parseJson(body, source);
          items = items.concat(outcome.items);
          if (outcome.note) notes.push(outcome.note);
        }
      } else {
        const body = await loadSourceBody(source, args);
        if (!body) {
          status.note = '样本模式未提供 fixture，已跳过';
          statuses.push(status);
          continue;
        }
        const outcome = source.type === 'html_links'
          ? parseHtmlLinks(body, source)
          : source.type === 'embedded_objects'
            ? parseEmbeddedObjects(body, source)
            : parseFeed(body, source);
        items = outcome.items;
        if (outcome.note) notes.push(outcome.note);
      }
      const parsed = items;
      // 没有日期的条目一律不要：僵尸 RSS 的旧闻往往既没日期、链接里也没有日期。
      const fresh = parsed.filter((item) => item.published
        && now.getTime() - item.published.getTime() <= maxAgeMs);
      for (const item of fresh) {
        item.sourceWeight = source.weight ?? 1;
        item.sourceKind = source.kind ?? 'news';
      }
      collected.push(...fresh);
      status.ok = fresh.length > 0;
      status.count = fresh.length;
      if (!status.ok) {
        const reasons = [];
        if (parsed.length === 0) {
          reasons.push('没有解析出条目');
        } else {
          const undated = parsed.filter((item) => !item.published).length;
          const stale = parsed.length - undated;
          if (undated > 0) reasons.push(`${undated} 条没有日期`);
          if (stale > 0) reasons.push(`${stale} 条超过 ${maxAgeDays} 天`);
        }
        if (notes.length > 0) reasons.push(...notes);
        status.note = reasons.join('，') || '没有可用条目';
      } else if (notes.length > 0) {
        status.note = notes.join('；');
      }
    } catch (error) {
      status.note = error.message;
    }
    statuses.push(status);
    log(`来源「${source.name}」${status.ok ? `✅ ${status.count} 条` : `❌ ${status.note}`}`);
  }

  const scored = dedupe(collected.map((item) => scoreItem(item, configObject, now)))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      const aTime = a.published ? a.published.getTime() : 0;
      const bTime = b.published ? b.published.getTime() : 0;
      return bTime - aTime;
    });

  return { scored, selected: selectWithQuotas(scored, configObject), statuses };
}

function extractiveItems(scored, maxItems, summaryMax) {
  return scored.slice(0, maxItems).map((item) => ({
    id: itemId(item),
    title: item.title,
    // 短评风格：只留第一句话，控制在 summaryMax 字以内；不能当短评用的噪声直接空掉
    summary: isWeakSummary(item.summary, item.title) ? '' : firstSentence(item.summary, summaryMax),
    category: item.category,
    tags: item.tags,
    source: item.source,
    link: item.link,
    published: item.published ? toIsoSeconds(item.published) : null,
    body: '',
    kind: 'news'
  }));
}

/// 抓每条要点的正文，塞进 JSON，App 内点进去就能直接读，不用跳网页。
async function attachBodies(items, maxChars, summaryMax) {
  let ok = 0;
  await Promise.all(items.map(async (item) => {
    if (!item.link || !item.link.startsWith('http')) return;
    try {
      const html = await fetchText(item.link);
      const body = extractArticleText(html, maxChars);
      if (body.length >= 80) {
        item.body = body;
        ok += 1;
        // 没有摘要时，用正文第一句补一条一句话简报（不依赖模型也有内容）
        if (!item.summary) {
          const candidate = bestBriefSentence(body, summaryMax);
          if (candidate) item.summary = candidate;
        }
      }
    } catch {
      // 抓不到就留空，App 会退回只显示要点摘要
    }
  }));
  log(`正文抓取完成：${ok}/${items.length} 条可在 App 内直接阅读`);
  return ok;
}

function writeOutputs(outDir, digest, today) {
  fs.mkdirSync(outDir, { recursive: true });
  const dated = path.join(outDir, `digest-${today}.json`);
  const latest = path.join(outDir, 'digest-latest.json');
  fs.writeFileSync(dated, `${JSON.stringify(digest, null, 2)}\n`, 'utf8');
  fs.writeFileSync(latest, `${JSON.stringify(digest, null, 2)}\n`, 'utf8');

  const indexPath = path.join(outDir, 'index.json');
  let index = [];
  if (fs.existsSync(indexPath)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
      if (Array.isArray(parsed)) index = parsed;
    } catch {
      index = [];
    }
  }
  index = index.filter((entry) => entry && entry.date !== digest.date);
  index.unshift({
    date: digest.date,
    count: digest.items.length,
    method: digest.method,
    generatedAt: digest.generatedAt
  });
  fs.writeFileSync(indexPath, `${JSON.stringify(index.slice(0, 60), null, 2)}\n`, 'utf8');
  return { dated, latest, indexPath };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const configObject = JSON.parse(fs.readFileSync(args.config, 'utf8'));

  if (args.probeUrl) {
    const html = await fetchText(args.probeUrl);
    const text = extractArticleText(html, 1200);
    console.log(`=== ${args.probeUrl} ===\n${text || '(没有抽到正文)'}`);
    return;
  }

  const today = beijingToday(args.today);
  const maxItems = configObject.max_items ?? 10;
  const minItems = configObject.min_items ?? 5;
  const publishFloor = configObject.publish_floor ?? 3;

  log(`开始生成 ${today} 的时政要点${args.fixtureDir ? '（离线样本模式）' : ''}`);
  const { scored, selected, statuses } = await collect(configObject, args);
  log(`抓取并去重后共 ${scored.length} 条候选`);

  if (scored.length < publishFloor) {
    log(`❌ 候选不足 ${publishFloor} 条，本次不写文件（保留上一次的要点），请检查上面的来源状态`);
    process.exit(1);
  }

  const llmItems = await refineWithLlm(selected, {
    maxItems,
    summaryMax: configObject.summary_max ?? 48,
    today,
    noLlm: args.noLlm || Boolean(args.fixtureDir)
  });
  const items = llmItems ?? extractiveItems(selected, maxItems, configObject.summary_max ?? 48);
  const method = llmItems ? 'llm' : 'extractive';

  log('抓取正文（App 内直接阅读用）…');
  await attachBodies(items, configObject.body_max_chars ?? 1200, configObject.summary_max ?? 48);

  const digest = {
    date: today,
    generatedAt: toIsoSeconds(new Date()),
    method,
    degraded: items.length < minItems,
    count: items.length,
    items,
    sources: statuses
  };

  const files = writeOutputs(args.outDir, digest, today);
  log(`写入 ${files.dated}`);
  log(`写入 ${files.latest}`);
  log(`共 ${items.length} 条要点，方式：${method}${digest.degraded ? '（条数偏少，已标记 degraded）' : ''}`);
  if (items.length < minItems) {
    log(`⚠️ 少于目标条数 ${minItems}，App 会照常显示，但内容可能不够看`);
  }
}

main().catch((error) => {
  console.error(`[digest] 失败：${error.stack || error.message}`);
  process.exit(1);
});
