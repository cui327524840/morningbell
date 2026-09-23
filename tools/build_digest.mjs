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

function parseDate(raw) {
  if (!raw) return null;
  const text = String(raw).trim();
  if (!text) return null;
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

请从中挑出 ${Math.min(5, maxItems)} 到 ${maxItems} 条最值得国考考生掌握的时政要点，输出严格 JSON，不要任何解释文字：

{"items":[{"source_index":0,"title":"不超过 30 字的标题","summary":"60~120 字的要点说明，说清是什么事、关键数字、为什么重要","category":"政治/经济/民生/法治/科技/生态/文化/外交/乡村 之一","tags":["考点标签1","考点标签2"]}]}

要求：
1. source_index 必须来自上面的编号，不得编造新闻，不得修改事实与数字。
2. 优先选会议决策、政策文件、重要讲话、重要经济数据、民生举措。
3. 同类事件只保留最重要的一条。
4. summary 要像给考生划重点，不要空话。`;
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
      const summary = cleanText(entry.summary, 240);
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

function extractiveItems(scored, maxItems) {
  return scored.slice(0, maxItems).map((item) => ({
    id: itemId(item),
    title: item.title,
    summary: item.summary || '（这条来自政策列表页，点开原文查看详情）',
    category: item.category,
    tags: item.tags,
    source: item.source,
    link: item.link,
    published: item.published ? toIsoSeconds(item.published) : null,
    kind: 'news'
  }));
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
    today,
    noLlm: args.noLlm || Boolean(args.fixtureDir)
  });
  const items = llmItems ?? extractiveItems(selected, maxItems);
  const method = llmItems ? 'llm' : 'extractive';

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
