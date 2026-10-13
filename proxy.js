'use strict';
/**
 * token-monitor  ——  本地 LLM 用量统计代理
 *
 * 你的程序把 API 的 base_url 指向本代理（默认 http://127.0.0.1:8788），
 * 代理原样转发到真正的上游（config.json 里的 upstream），同时统计每次请求的
 * token 用量，写入 data/usage.jsonl，并通过 /__stats 接口实时对外提供数据。
 *
 * 命令：
 *   node proxy.js            启动代理
 *   node proxy.js --widget   启动代理并弹出桌面悬浮窗
 *   node proxy.js --mock     不访问真实上游，本地伪造响应（用于自测/演示）
 *   node proxy.js --reset    清空历史统计后退出
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { URL } = require('url');
const { spawn } = require('child_process');

const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, 'data');
const USAGE_LOG = path.join(DATA_DIR, 'usage.jsonl');
const CONFIG_FILE = path.join(ROOT, 'config.json');
const DASHBOARD_FILE = path.join(ROOT, 'dashboard.html');

const DEFAULT_CONFIG = {
  port: 8788,
  host: '127.0.0.1',
  // 真正要访问的上游。末尾带不带 /v1 都可以，代理会自动去重。
  upstream: 'https://api.deepseek.com',
  // 上游没返回 usage 时，是否按字符粗略估算 token
  estimateWhenMissing: true,
  // 流式请求时自动补 stream_options.include_usage，让上游在最后一块返回 usage
  injectUsage: true,
  // 本代理自己伪造响应，不访问上游
  mock: false,
  // 余额查询：接口路径、刷新间隔（秒）、以及用哪个 key
  balancePath: '/user/balance',
  balanceRefreshSeconds: 120,
  apiKey: '',
  apiKeyEnv: 'DEEPSEEK_API_KEY',
  currency: '¥',
  // 价格表（每 100 万 token）。留空 = 用下面内置的，并优先用官网自动抓取的结果。
  // 固定价： { "input": 2, "output": 8 }
  // 分时段： { "inputHit": {"peak":0.04,"offPeak":0.02}, "inputMiss": {"peak":2,"offPeak":1}, "output": {"peak":8,"offPeak":4} }
  // 这里填的条目会「覆盖」官网价，用于手动锁定某个模型的价格。
  pricing: {},
  // 价格来源与自动更新
  pricingUrl: 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing',
  pricingAutoRefresh: true,
  pricingRefreshDays: 7,
  pricingCheckMinutes: 30,
  // 法定节假日。官方口径是「北京时间周一至周五（不含中国法定节假日）9:00-12:00、14:00-18:00 为高峰；
  // 其余时段，包括周末及法定节假日全天均为空闲」，所以周末和节假日要按空闲（半价）算。
  // 这里手写的日期会覆盖/补充自动获取的结果，写法："2026-10-01" 或 { "date": "2026-10-01", "name": "国庆节" }
  holidays: [],
  // 节假日表自动获取（内置表只有 2026 年，之后靠这个自动跟上；取不到就继续用内置表 + 上面手写的）
  holidaysUrl: 'https://timor.tech/api/holiday/year/{year}',
  holidaysAutoRefresh: true,
  holidaysRefreshDays: 30,
  // 是否把 DSH 会话自身的 token 用量也算进"总用量"（启动时读取一次）
  includeDshUsage: true,
  dshUsageDir: ''
};

// 内置价格：取自 DeepSeek 官方「模型 & 价格」页（2026-10 核对）。
// 高峰时段 = 北京时间周一至周五 9:00-12:00、14:00-18:00（不含法定节假日），其余时间按空闲价（半价）。
const BUILTIN_PRICING = {
  'deepseek-flash': {
    inputHit: { offPeak: 0.02, peak: 0.04 },
    inputMiss: { offPeak: 1, peak: 2 },
    output: { offPeak: 4, peak: 8 }
  },
  'deepseek-v4-pro': {
    inputHit: { offPeak: 0.15, peak: 0.3 },
    inputMiss: { offPeak: 4.5, peak: 9 },
    output: { offPeak: 13.5, peak: 27 }
  }
};
// 内置法定节假日（来源：国务院办公厅《关于 2026 年部分节假日安排的通知》，2026-10 核对）。
// 只列"放假"的日期；调休上班的周末仍然是周末，按空闲价算，所以不用列。
const BUILTIN_HOLIDAYS = {
  '2026-01-01': '元旦', '2026-01-02': '元旦', '2026-01-03': '元旦',
  '2026-02-15': '春节', '2026-02-16': '春节', '2026-02-17': '春节', '2026-02-18': '春节',
  '2026-02-19': '春节', '2026-02-20': '春节', '2026-02-21': '春节', '2026-02-22': '春节',
  '2026-02-23': '春节',
  '2026-04-04': '清明节', '2026-04-05': '清明节', '2026-04-06': '清明节',
  '2026-05-01': '劳动节', '2026-05-02': '劳动节', '2026-05-03': '劳动节', '2026-05-04': '劳动节',
  '2026-05-05': '劳动节',
  '2026-06-19': '端午节', '2026-06-20': '端午节', '2026-06-21': '端午节',
  '2026-09-25': '中秋节', '2026-09-26': '中秋节', '2026-09-27': '中秋节',
  '2026-10-01': '国庆节', '2026-10-02': '国庆节', '2026-10-03': '国庆节', '2026-10-04': '国庆节',
  '2026-10-05': '国庆节', '2026-10-06': '国庆节', '2026-10-07': '国庆节'
};
// 只有这些接口会产生 token 消耗；/models 之类的查询不该进统计
const BILLABLE_PATH = /\/(chat\/completions|completions|embeddings|responses|messages|rerank)\/?$/;

const argv = process.argv.slice(2);
const hasFlag = (name) => argv.includes(name);
const flagValue = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

fs.mkdirSync(DATA_DIR, { recursive: true });

function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(DEFAULT_CONFIG, null, 2) + '\n', 'utf8');
  }
  let raw = {};
  try {
    raw = readJsonFile(CONFIG_FILE);
  } catch (err) {
    console.error('[config] config.json 解析失败，改用默认配置：' + err.message);
  }
  const merged = Object.assign({}, DEFAULT_CONFIG, raw);
  // 价格表的合并（内置 / 官网抓取 / config.json 覆盖）在后面 buildPricingTable() 里做
  return merged;
}

const config = loadConfig();
if (hasFlag('--mock')) config.mock = true;
if (hasFlag('--upstream')) config.upstream = flagValue('--upstream', config.upstream);
if (hasFlag('--api-key')) config.apiKey = flagValue('--api-key', config.apiKey);
config.port = parseInt(flagValue('--port', config.port), 10);
// 仅用于测试时段配色/计价：强制按高峰或空闲计价
let forcedPeak = null;
if (hasFlag('--force-peak')) forcedPeak = true;
if (hasFlag('--force-offpeak')) forcedPeak = false;

/* ------------------------------------------------------------------ *
 * 价格表：内置 → 官网自动抓取 → config.json 手动覆盖
 * ------------------------------------------------------------------ */

const PRICING_CACHE_FILE = path.join(DATA_DIR, 'pricing.json');

let pricingTable = {};      // 当前生效的价格表
let pricingCache = null;    // data/pricing.json 的内容 { fetchedAt, source, models }
const pricingMeta = {
  label: '内置官方价',
  url: DEFAULT_CONFIG.pricingUrl,
  fetchedAt: null,
  nextRefreshAt: null,
  error: null,
  loading: false,
  manualOverrides: []
};

function refreshDays() {
  const days = Number(config.pricingRefreshDays);
  return days > 0 ? days : 7;
}

function decodeEntities(text) {
  return String(text)
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (m, d) => String.fromCharCode(parseInt(d, 10)));
}

function cellText(html) {
  return decodeEntities(String(html).replace(/<sup[\s\S]*?<\/sup>/gi, ' ').replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

/** 把一张 HTML 表格解析成二维网格，正确处理 rowspan / colspan。 */
function parseTableGrid(tableHtml) {
  const rows = tableHtml.match(/<tr[\s\S]*?<\/tr>/gi) || [];
  const grid = [];
  const carry = [];   // carry[col] = { text, left }：被 rowspan 占住、还在往下延伸的格子
  for (const rowHtml of rows) {
    const cells = rowHtml.match(/<t[dh][\s\S]*?<\/t[dh]>/gi) || [];
    const row = [];
    let col = 0;
    const takeCarry = () => {
      while (carry[col] && carry[col].left > 0) {
        row[col] = carry[col].text;
        carry[col].left -= 1;
        col += 1;
      }
    };
    for (const cellHtml of cells) {
      takeCarry();
      const attr = (cellHtml.match(/<t[dh]([^>]*)>/i) || [])[1] || '';
      const rs = parseInt((attr.match(/rowspan\s*=\s*"?(\d+)/i) || [])[1] || '1', 10);
      const cs = parseInt((attr.match(/colspan\s*=\s*"?(\d+)/i) || [])[1] || '1', 10);
      const text = cellText(cellHtml);
      for (let k = 0; k < cs; k += 1) {
        row[col] = text;
        if (rs > 1) carry[col] = { text, left: rs - 1 };
        col += 1;
      }
    }
    takeCarry();
    grid.push(row);
  }
  return grid;
}

/** 从官网价格页 HTML 里解析出 { 模型: { inputHit, inputMiss, output } }。 */
function parsePricingHtml(html) {
  const tables = String(html).match(/<table[\s\S]*?<\/table>/gi) || [];
  const table = tables.find((t) => t.includes('百万tokens') && t.includes('缓存'));
  if (!table) throw new Error('页面上找不到价格表（官网可能改版了）');
  const grid = parseTableGrid(table);

  const headerRow = grid.find((r) => String(r[0] || '').includes('模型'));
  if (!headerRow) throw new Error('价格表里找不到表头行');
  const modelCols = [];
  for (let c = 0; c < headerRow.length; c += 1) {
    const name = String(headerRow[c] || '').replace(/\(\d+\)\s*$/, '').trim();
    if (/^[a-z0-9][a-z0-9._-]*$/i.test(name) && /deepseek|gpt|claude|gemini|qwen|glm|kimi|llama/i.test(name)) {
      modelCols.push({ col: c, name });
    }
  }
  if (!modelCols.length) throw new Error('价格表里没有识别到模型列');

  const models = {};
  for (const m of modelCols) models[m.name] = { inputHit: {}, inputMiss: {}, output: {} };

  const metricOf = (text) => {
    if (/未命中/.test(text)) return 'inputMiss';
    if (/命中/.test(text)) return 'inputHit';
    if (/输出/.test(text)) return 'output';
    return null;
  };
  const tierOf = (text) => (/高峰/.test(text) ? 'peak' : (/空闲/.test(text) ? 'offPeak' : null));

  let picked = 0;
  for (const row of grid) {
    if (!String(row[0] || '').includes('价格')) continue;
    const metric = metricOf(String(row[1] || ''));
    const tier = tierOf(String(row[2] || ''));
    if (!metric || !tier) continue;
    for (const m of modelCols) {
      const value = parseFloat(String(row[m.col] || '').replace(/[^\d.]/g, ''));
      if (!isFinite(value)) continue;
      models[m.name][metric][tier] = value;
      picked += 1;
    }
  }
  if (!picked) throw new Error('价格表里没有解析到任何价格数字');

  for (const [name, entry] of Object.entries(models)) {
    for (const metric of ['inputHit', 'inputMiss', 'output']) {
      for (const tier of ['offPeak', 'peak']) {
        const value = entry[metric][tier];
        if (typeof value !== 'number' || !(value > 0)) {
          throw new Error(`模型 ${name} 的 ${metric}.${tier} 价格缺失`);
        }
      }
    }
  }
  return { models };
}

function fetchPricingPage(url, depth, accept) {
  const level = depth || 0;
  return new Promise((resolve, reject) => {
    if (level > 5) return reject(new Error('重定向次数过多'));
    let target;
    try { target = new URL(url); } catch { return reject(new Error('价格页地址无效')); }
    const lib = target.protocol === 'https:' ? https : http;
    const req = lib.get(target, {
      headers: { 'user-agent': 'token-monitor/1.0 (local price fetcher)', accept: accept || 'text/html' },
      timeout: 20000
    }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(fetchPricingPage(new URL(res.headers.location, target).toString(), level + 1, accept));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error('HTTP ' + res.statusCode));
      }
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { text += c; });
      res.on('end', () => resolve(text));
    });
    req.on('timeout', () => req.destroy(new Error('抓取价格页超时')));
    req.on('error', reject);
  });
}

/** 读取 JSON 文件：容忍记事本之类工具写进去的 UTF-8 BOM。 */
function readJsonFile(file) {
  let text = fs.readFileSync(file, 'utf8');
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  return JSON.parse(text);
}

function loadPricingCache() {
  try {
    if (!fs.existsSync(PRICING_CACHE_FILE)) return;
    const data = readJsonFile(PRICING_CACHE_FILE);
    if (data && data.models && Object.keys(data.models).length) pricingCache = data;
  } catch (err) {
    console.error('[pricing] 读取价格缓存失败：' + err.message);
  }
}

/** 合并价格表：内置 → 官网抓取 → config.json 覆盖。 */
function buildPricingTable() {
  const table = {};
  for (const [k, v] of Object.entries(BUILTIN_PRICING)) table[k] = v;
  let label = '内置官方价';
  let fetchedAt = null;
  if (pricingCache && pricingCache.models) {
    for (const [k, v] of Object.entries(pricingCache.models)) table[k] = v;
    label = '官网自动获取';
    fetchedAt = pricingCache.fetchedAt || null;
  }
  const manual = Object.keys(config.pricing || {});
  for (const k of manual) table[k] = config.pricing[k];
  if (manual.length) label += '（含手动覆盖）';

  pricingTable = table;
  pricingMeta.label = label;
  pricingMeta.fetchedAt = fetchedAt;
  pricingMeta.manualOverrides = manual;
  pricingMeta.nextRefreshAt = fetchedAt
    ? fetchedAt + refreshDays() * 24 * 3600 * 1000
    : Date.now();
}

function pricingFetchedText() {
  if (!pricingMeta.fetchedAt) return '';
  const d = new Date(pricingMeta.fetchedAt + 8 * 3600 * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())} 更新`;
}

function pricingSnapshot() {
  return {
    ok: !pricingMeta.error,
    label: pricingMeta.label,
    source: pricingMeta.url,
    fetchedAt: pricingMeta.fetchedAt,
    fetchedText: pricingFetchedText(),
    nextRefreshAt: pricingMeta.nextRefreshAt,
    refreshDays: refreshDays(),
    autoRefresh: config.pricingAutoRefresh !== false,
    manualOverrides: pricingMeta.manualOverrides,
    error: pricingMeta.error,
    loading: pricingMeta.loading,
    table: pricingTable
  };
}

/** 需要时抓取官网价格。force = true 忽略缓存与开关。 */
function refreshPricing(force, done) {
  const finish = () => { if (typeof done === 'function') done(); };
  if (pricingMeta.loading) return finish();
  if (!force) {
    if (config.pricingAutoRefresh === false) return finish();
    const intervalMs = refreshDays() * 24 * 3600 * 1000;
    if (pricingMeta.fetchedAt && Date.now() - pricingMeta.fetchedAt < intervalMs) return finish();
  }
  const url = config.pricingUrl || DEFAULT_CONFIG.pricingUrl;
  pricingMeta.url = url;
  pricingMeta.loading = true;
  fetchPricingPage(url).then((html) => {
    const parsed = parsePricingHtml(html);
    pricingCache = { fetchedAt: Date.now(), source: url, models: parsed.models };
    fs.writeFileSync(PRICING_CACHE_FILE, JSON.stringify(pricingCache, null, 2), 'utf8');
    pricingMeta.error = null;
    pricingMeta.loading = false;
    buildPricingTable();
    pushSnapshot();
    console.log(`[pricing] 已从官网更新价格：${Object.keys(parsed.models).join('、')}`);
    finish();
  }).catch((err) => {
    pricingMeta.loading = false;
    pricingMeta.error = '价格更新失败：' + err.message + '（继续沿用现有价格）';
    console.error('[pricing] ' + pricingMeta.error);
    buildPricingTable();
    finish();
  });
}

/** 每 config.pricingCheckMinutes 分钟检查一次，超过 7 天就自动更新。 */
function schedulePricingRefresh() {
  const minutes = Number(config.pricingCheckMinutes) > 0 ? Number(config.pricingCheckMinutes) : 30;
  const timer = setInterval(() => {
    if (config.pricingAutoRefresh === false) return;
    const intervalMs = refreshDays() * 24 * 3600 * 1000;
    if (!pricingMeta.fetchedAt || Date.now() - pricingMeta.fetchedAt >= intervalMs) {
      refreshPricing(false);
    }
  }, minutes * 60 * 1000);
  if (timer.unref) timer.unref();
}

/* ------------------------------------------------------------------ *
 * 法定节假日表（高峰/空闲判定要用）
 *
 * 官方口径：北京时间周一至周五（不含中国法定节假日）9:00-12:00、14:00-18:00 为高峰时段；
 * 其余时段，包括周末及中国法定节假日全天均为空闲时段（半价）。
 * 所以「今天是节假日」必须能算出来，否则节假日白天会按高峰价显示（2026-10-05 国庆期间就报错过）。
 * 三级来源：内置表（当年） → data/holidays.json 自动获取 → config.json 的 holidays 手写覆盖。
 * ------------------------------------------------------------------ */

const HOLIDAY_CACHE_FILE = path.join(DATA_DIR, 'holidays.json');

let holidayCache = null;          // { fetchedAt, source, days: { 'YYYY-MM-DD': 名称 } }
let holidayTableCache = null;     // 合并后的生效表，改数据时置空
const holidayMeta = {
  label: '内置节假日表',
  source: null,
  fetchedAt: null,
  error: null,
  loading: false,
  years: []
};

function loadHolidayCache() {
  try {
    if (!fs.existsSync(HOLIDAY_CACHE_FILE)) return;
    const data = readJsonFile(HOLIDAY_CACHE_FILE);
    if (data && data.days && Object.keys(data.days).length) {
      holidayCache = data;
      holidayTableCache = null;
      holidayMeta.fetchedAt = data.fetchedAt || null;
      holidayMeta.source = data.source || null;
      holidayMeta.years = data.years || [];
      holidayMeta.label = '自动获取（' + (data.years || []).join('、') + ' 年）+ 内置表';
    }
  } catch (err) {
    console.error('[holiday] 读取节假日缓存失败：' + err.message);
  }
}

/** 生效的节假日表：内置 → 自动获取 → config.json 手写。 */
function holidayTable() {
  if (holidayTableCache) return holidayTableCache;
  const table = Object.assign({}, BUILTIN_HOLIDAYS);
  if (holidayCache && holidayCache.days) Object.assign(table, holidayCache.days);
  const manual = Array.isArray(config.holidays) ? config.holidays : [];
  for (const item of manual) {
    if (typeof item === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(item)) table[item] = '法定节假日';
    else if (item && typeof item === 'object' && typeof item.date === 'string') table[item.date] = item.name || '法定节假日';
  }
  holidayTableCache = table;
  return table;
}

/** 北京时间下的日期键（YYYY-MM-DD）、星期（0=周日）、当天分钟数。 */
function beijingParts(ts) {
  const d = new Date((ts || Date.now()) + 8 * 3600 * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return {
    key: `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`,
    day: d.getUTCDay(),
    minutes: d.getUTCHours() * 60 + d.getUTCMinutes()
  };
}

/** 现在是高峰还是空闲，并给出原因（界面提示与排查都靠它）。 */
function peakInfo(ts) {
  const t = ts || Date.now();
  if (forcedPeak !== null) {
    return { peak: forcedPeak, reason: forcedPeak ? '命令行强制高峰' : '命令行强制空闲', holiday: null };
  }
  const p = beijingParts(t);
  const holiday = holidayTable()[p.key] || null;
  if (p.day === 0 || p.day === 6) return { peak: false, reason: '周末（全天空闲）', holiday };
  if (holiday) return { peak: false, reason: `法定节假日 · ${holiday}（全天空闲）`, holiday };
  if ((p.minutes >= 9 * 60 && p.minutes < 12 * 60) || (p.minutes >= 14 * 60 && p.minutes < 18 * 60)) {
    return { peak: true, reason: '工作日高峰时段', holiday: null };
  }
  return { peak: false, reason: '工作日非高峰时段', holiday: null };
}

/** 是否处于高峰时段：周一至周五 9:00-12:00、14:00-18:00，周末与法定节假日全天空闲。 */
function isPeakNow(ts) {
  return peakInfo(ts).peak;
}

/**
 * 下一次高峰/空闲切换的时刻。
 * 高峰只会在 09:00 / 12:00 / 14:00 / 18:00 以及跨天（周末、节假日）时变化，
 * 所以只在这些点上试算，不用逐分钟扫。
 */
function nextPeakChange(ts) {
  const now = ts || Date.now();
  const from = peakInfo(now).peak;
  const p = beijingParts(now);
  const ymd = p.key.split('-').map(Number);
  const dayStart = Date.UTC(ymd[0], ymd[1] - 1, ymd[2]) - 8 * 3600 * 1000;   // 北京时间的零点
  const marks = [0, 9 * 60, 12 * 60, 14 * 60, 18 * 60];
  for (let i = 0; i <= 10; i += 1) {
    for (const mk of marks) {
      const t = dayStart + i * 86400000 + mk * 60000;
      if (t <= now) continue;
      if (peakInfo(t).peak !== from) return t;
    }
  }
  return null;
}

/**
 * 当前这一段「时段」是从什么时候开始、什么时候结束、已经过去了百分之多少。
 *
 * 为什么要算起点：只靠 nextPeakChange() 能知道"还剩多久"，但算不出"已过百分之多少"——
 * 高峰一段只有 3 小时（9:00-12:00 / 14:00-18:00），空闲则可能连着好几天（周末 + 法定节假日），
 * 所以必须知道这一段的起点。
 *
 * 找法：档位只会在 00:00 / 09:00 / 12:00 / 14:00 / 18:00 这几个点变化，
 * 所以把这些点当栅格，往前扫到第一个档位不同的点（那就是本段起点）、
 * 往后取 nextPeakChange()（本段终点）。**不要用"从今天往回逐分钟扫"的写法**：
 * 2026-10-01~10-07 连着放假，空闲段能从 9 月底一路连到 10 月 8 日早上，
 * 超过 30 天，那种写法会直接把窗口判成"算不出来"（踩过）。
 */
function peakWindow(ts) {
  const now = ts || Date.now();
  const info = peakInfo(now);
  if (forcedPeak !== null) return null;   // 强制时段是测试开关，没有真实的起止
  const end = nextPeakChange(now);
  if (!end) return null;

  // 本段起点：档位只会在下面这几个"栅格点"上变化，所以先用栅格夹出一个小区间，
  // 再在区间里逐分钟逼近——区间最宽 15 小时（跨夜那段空闲），逐分钟扫也就千次左右。
  // 关键：夹逼要用「最后一个同档的栅格点」当下界、「它后面那个异档点」当上界，
  // 真正的切换一定落在这一格里面（直接用"上一个异档点"当起点会把 09:00 的高峰起点算成 00:00）。
  const p = beijingParts(now);
  const ymd = p.key.split('-').map(Number);
  const dayStart = Date.UTC(ymd[0], ymd[1] - 1, ymd[2]) - 8 * 3600 * 1000;
  const marks = [0, 9 * 60, 12 * 60, 14 * 60, 18 * 60];
  const grid = [];
  for (let i = 0; i <= 40; i += 1) {                     // 8 天够用，多留余量
    for (const mk of marks) {
      const t = dayStart - i * 86400000 + mk * 60000;
      if (t < now) grid.push(t);
    }
  }
  grid.sort((a, b) => b - a);                            // 从近到远
  let diffIdx = -1;
  for (let i = 0; i < grid.length; i += 1) {
    if (peakInfo(grid[i]).peak !== info.peak) { diffIdx = i; break; }
  }
  if (diffIdx <= 0) return null;                         // 没找到 / 全段同档：交给调用方显示"—"
  const lower = grid[diffIdx];                           // 最后一个同档栅格点
  const upper = grid[diffIdx - 1];                       // 它后面那个异档点（本段起点 <= upper）
  // 逐分钟找"切换发生在哪一分钟"：第一个和前一分钟档位不同的点就是起点
  // （注意：lower 自己就是切换后的第一个栅格点，所以不能拿"第一个和 now 不同档的点"当起点）
  let start = upper;
  for (let t = lower + 60000; t <= upper; t += 60000) {
    if (peakInfo(t).peak !== peakInfo(t - 60000).peak) { start = t; break; }
  }
  const totalMs = end - start;
  if (totalMs <= 0) return null;
  return {
    peak: info.peak,
    tierText: info.peak ? '高峰' : '空闲',
    startAt: start,
    endAt: end,
    totalMs,
    elapsedMs: now - start,
    remainMs: end - now,
    percent: Math.max(0, Math.min(100, ((now - start) / totalMs) * 100))
  };
}

function holidaySnapshot() {
  const table = holidayTable();
  const dates = Object.keys(table).sort();
  const todayKey = beijingParts().key;
  const year = todayKey.slice(0, 4);
  return {
    ok: !holidayMeta.error,
    label: holidayMeta.label,
    source: holidayMeta.source,
    fetchedAt: holidayMeta.fetchedAt,
    years: holidayMeta.years,
    error: holidayMeta.error,
    loading: holidayMeta.loading,
    total: dates.length,
    currentYear: year,
    currentYearCount: dates.filter((d) => d.startsWith(year)).length,
    manual: Array.isArray(config.holidays) ? config.holidays.length : 0,
    builtinYears: [...new Set(Object.keys(BUILTIN_HOLIDAYS).map((d) => d.slice(0, 4)))],
    upcoming: dates.filter((d) => d >= todayKey).slice(0, 6).map((d) => ({ date: d, name: table[d] }))
  };
}

/** 抓某一年的节假日（只取"放假"的日期，调休上班的周末不算）。 */
function fetchHolidayYear(year) {
  const template = config.holidaysUrl || DEFAULT_CONFIG.holidaysUrl;
  const url = template.replace('{year}', String(year));
  return fetchPricingPage(url, 0, 'application/json').then((text) => {
    const doc = JSON.parse(text);
    const days = {};
    const map = (doc && doc.holiday) || {};
    for (const key of Object.keys(map)) {
      const item = map[key] || {};
      if (item.holiday !== true) continue;
      const date = /^\d{4}-\d{2}-\d{2}$/.test(item.date || '') ? item.date : `${year}-${key}`;
      days[date] = item.name || '法定节假日';
    }
    return days;
  });
}

/** 需要时抓取节假日表。force = true 忽略缓存与开关。 */
function refreshHolidays(force, done) {
  const finish = () => { if (typeof done === 'function') done(); };
  if (holidayMeta.loading) return finish();
  if (!force && config.holidaysAutoRefresh === false) return finish();
  const days = Number(config.holidaysRefreshDays) > 0 ? Number(config.holidaysRefreshDays) : 30;
  if (!force && holidayCache && holidayCache.fetchedAt
      && Date.now() - holidayCache.fetchedAt < days * 24 * 3600 * 1000) return finish();

  const year = Number(beijingParts().key.slice(0, 4));
  const years = [year, year + 1];        // 下一年的安排每年 11 月前后公布，一起拿，跨年不用等
  holidayMeta.loading = true;
  holidayMeta.source = config.holidaysUrl || DEFAULT_CONFIG.holidaysUrl;
  Promise.all(years.map((y) => fetchHolidayYear(y).catch((err) => {
    console.error(`[holiday] ${y} 年节假日获取失败：${err.message}`);
    return null;
  }))).then((results) => {
    const merged = (holidayCache && holidayCache.days) ? Object.assign({}, holidayCache.days) : {};
    const got = [];
    results.forEach((daysOfYear, i) => {
      if (!daysOfYear || !Object.keys(daysOfYear).length) return;   // 还没公布的年（如下一年的安排）不算获取成功
      Object.assign(merged, daysOfYear);
      got.push(String(years[i]));
    });
    holidayMeta.loading = false;
    if (!got.length) {
      holidayMeta.error = '节假日表自动获取失败（继续用内置表 + config.json 里手写的日期）';
      console.error('[holiday] ' + holidayMeta.error);
      return finish();
    }
    holidayCache = { fetchedAt: Date.now(), source: holidayMeta.source, days: merged, years: got };
    holidayTableCache = null;
    fs.writeFileSync(HOLIDAY_CACHE_FILE, JSON.stringify(holidayCache, null, 2), 'utf8');
    holidayMeta.fetchedAt = holidayCache.fetchedAt;
    holidayMeta.years = got;
    holidayMeta.label = '自动获取（' + got.join('、') + ' 年）+ 内置表';
    holidayMeta.error = null;
    console.log(`[holiday] 已更新节假日表：${got.join('、')} 年，共 ${Object.keys(merged).length} 天`);
    pushSnapshot();
    finish();
  }).catch((err) => {
    holidayMeta.loading = false;
    holidayMeta.error = '节假日表自动获取失败：' + err.message;
    console.error('[holiday] ' + holidayMeta.error);
    finish();
  });
}

/** 每小时检查一次，超过 config.holidaysRefreshDays 天就自动更新。 */
function scheduleHolidayRefresh() {
  const timer = setInterval(() => {
    if (config.holidaysAutoRefresh === false) return;
    refreshHolidays(false);
  }, 60 * 60 * 1000);
  if (timer.unref) timer.unref();
}

/* ------------------------------------------------------------------ *
 * 统计状态
 * ------------------------------------------------------------------ */

const EMPTY_BUCKET = () => ({ requests: 0, errors: 0, prompt: 0, completion: 0, total: 0, estimated: 0, cost: 0, costKnown: false });
const state = {
  startedAt: Date.now(),
  totals: Object.assign(EMPTY_BUCKET(), { estimated: 0 }),
  byModel: new Map(),
  byDay: new Map(),
  recent: [],
  last: null,
  rate: { completionPerSec: 0, latencyMs: 0 }
};

function bucket(map, key) {
  if (!map.has(key)) map.set(key, Object.assign(EMPTY_BUCKET(), { key }));
  return map.get(key);
}

function dayKey(ts) {
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 把一条记录累加进统计。返回这条记录。 */
function applyRecord(rec) {
  const b = state.totals;
  b.requests += 1;
  if (rec.error) b.errors += 1;
  b.prompt += rec.prompt;
  b.completion += rec.completion;
  b.total += rec.total;
  if (rec.estimated) b.estimated += 1;
  if (typeof rec.cost === 'number') { b.cost += rec.cost; b.costKnown = true; }

  const m = bucket(state.byModel, rec.model || '未知模型');
  m.requests += 1;
  m.prompt += rec.prompt;
  m.completion += rec.completion;
  m.total += rec.total;
  if (rec.error) m.errors += 1;
  if (typeof rec.cost === 'number') { m.cost += rec.cost; m.costKnown = true; }

  const d = bucket(state.byDay, dayKey(rec.ts));
  d.requests += 1;
  d.prompt += rec.prompt;
  d.completion += rec.completion;
  d.total += rec.total;
  if (rec.error) d.errors += 1;
  if (typeof rec.cost === 'number') { d.cost += rec.cost; d.costKnown = true; }

  state.last = rec;
  state.recent.push(rec);
  if (state.recent.length > 30) state.recent.shift();

  if (rec.completion > 0 && rec.latencyMs > 0) {
    state.rate = {
      completionPerSec: Math.round((rec.completion / (rec.latencyMs / 1000)) * 10) / 10,
      latencyMs: rec.latencyMs
    };
  }
  return rec;
}

/** 启动时重放历史，保证「今日累计」跨重启仍然正确。 */
function replayHistory() {
  if (!fs.existsSync(USAGE_LOG)) return;
  let lines = 0;
  for (const line of fs.readFileSync(USAGE_LOG, 'utf8').split('\n')) {
    const text = line.trim();
    if (!text) continue;
    try {
      applyRecord(JSON.parse(text));
      lines += 1;
    } catch { /* 忽略损坏行 */ }
  }
  const replay = state.totals.requests;
  state.recent = state.recent.slice(-30);
  state.totals = Object.assign(EMPTY_BUCKET(), state.totals);
  if (lines) {
    console.log(`[history] 已从 usage.jsonl 恢复 ${replay} 条历史记录`);
  }
}

function persist(rec) {
  fs.appendFile(USAGE_LOG, JSON.stringify(rec) + '\n', (err) => {
    if (err) console.error('[log] 写入失败：' + err.message);
  });
}

/* ------------------------------------------------------------------ *
 * token 估算（上游没给 usage 时的兜底）
 * ------------------------------------------------------------------ */

function estimateTokens(text) {
  if (!text) return 0;
  const cjk = (text.match(/[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]/g) || []).length;
  const rest = text.length - cjk;
  return Math.max(0, Math.ceil(cjk * 1.0 + rest / 4));
}

/** 从请求体里抽出提示词文本，仅用于估算和 mock。 */
function extractPromptText(body) {
  if (!body || typeof body !== 'object') return '';
  const parts = [];
  if (typeof body.prompt === 'string') parts.push(body.prompt);
  if (Array.isArray(body.prompt)) parts.push(body.prompt.join('\n'));
  if (Array.isArray(body.messages)) {
    for (const msg of body.messages) {
      if (!msg) continue;
      if (typeof msg.content === 'string') parts.push(msg.content);
      else if (Array.isArray(msg.content)) {
        for (const seg of msg.content) if (seg && typeof seg.text === 'string') parts.push(seg.text);
      }
      if (msg.tool_calls) parts.push(JSON.stringify(msg.tool_calls));
    }
  }
  if (Array.isArray(body.input)) parts.push(JSON.stringify(body.input));
  return parts.join('\n');
}

/** 兼容 prompt_tokens / input_tokens 等不同命名。 */
function pickUsage(usage) {
  if (!usage || typeof usage !== 'object') return null;
  const num = (...keys) => {
    for (const k of keys) if (typeof usage[k] === 'number') return usage[k];
    return null;
  };
  const prompt = num('prompt_tokens', 'input_tokens', 'promptTokens', 'inputTokens', 'prompt');
  const completion = num('completion_tokens', 'output_tokens', 'completionTokens', 'outputTokens', 'completion');
  const total = num('total_tokens', 'totalTokens', 'total');
  if (prompt === null && completion === null && total === null) return null;
  // DeepSeek 会分别给出命中/未命中缓存的输入 token，用来区分输入单价。
  // 同时兼容本函数自己的输出（二次解析时字段名是 hit / miss / reasoning）。
  const details = usage.prompt_tokens_details || {};
  let hit = num('prompt_cache_hit_tokens', 'cache_hit_tokens', 'hit');
  if (hit === null && typeof details.cached_tokens === 'number') hit = details.cached_tokens;
  let miss = num('prompt_cache_miss_tokens', 'miss');
  if (miss === null && hit !== null && prompt !== null) miss = Math.max(0, prompt - hit);
  const completionDetails = usage.completion_tokens_details || {};
  const reasoning = typeof completionDetails.reasoning_tokens === 'number'
    ? completionDetails.reasoning_tokens
    : num('reasoning_tokens', 'reasoning');
  return { prompt, completion, total, hit, miss, reasoning };
}

/** 从响应体里抽出模型输出的文本，仅用于估算。 */
function extractResponseText(json) {
  if (!json || typeof json !== 'object') return '';
  if (typeof json.output_text === 'string') return json.output_text;
  const parts = [];
  if (Array.isArray(json.choices)) {
    for (const c of json.choices) {
      if (!c) continue;
      const content = (c.message && c.message.content) || c.text;
      if (typeof content === 'string') parts.push(content);
      if (c.message && c.message.tool_calls) parts.push(JSON.stringify(c.message.tool_calls));
    }
  }
  if (Array.isArray(json.content)) {
    for (const seg of json.content) if (seg && typeof seg.text === 'string') parts.push(seg.text);
  }
  return parts.join('');
}

/* ------------------------------------------------------------------ *
 * 价格与时段（高峰 / 空闲）
 * ------------------------------------------------------------------ */

/** 按北京时间判断是否处于高峰时段 —— 实现在上面「法定节假日表」一节（peakInfo），这里不要再写一份。 */

function priceEntry(model) {
  if (!model) return null;
  const table = pricingTable || {};
  if (table[model]) return { key: model, value: table[model] };
  const key = Object.keys(table).find((k) => model.startsWith(k));
  return key ? { key, value: table[key] } : null;
}

/** 把价格表里的一项换算成指定时段的实际单价（每 100 万 token）。 */
function effectivePrice(model, peak) {
  const entry = priceEntry(model);
  if (!entry) return null;
  const tier = peak ? 'peak' : 'offPeak';
  const pick = (v) => {
    if (typeof v === 'number') return v;
    if (v && typeof v === 'object') return typeof v[tier] === 'number' ? v[tier] : null;
    return null;
  };
  const v = entry.value;
  // 只有 input/output 是「数字」时才算固定价；分时段的写法里 output 是对象
  const fixed = typeof v.input === 'number' || typeof v.output === 'number';
  return {
    model: entry.key,
    isBuiltin: pricingMeta.label === '内置官方价',
    peak: !!peak,
    tierText: peak ? '高峰' : '空闲',
    currency: config.currency || '',
    inputHit: fixed ? (typeof v.input === 'number' ? v.input : (v.output || 0)) : pick(v.inputHit),
    inputMiss: fixed ? (typeof v.input === 'number' ? v.input : (v.output || 0)) : pick(v.inputMiss),
    output: fixed ? (typeof v.output === 'number' ? v.output : 0) : pick(v.output)
  };
}

/** 单次请求成本：命中缓存的输入、未命中的输入、输出分别计价。 */
function costOfRecord(rec) {
  const price = effectivePrice(rec.model, rec.peak);
  if (!price) return null;
  const hit = rec.cacheHit || 0;
  const miss = rec.cacheMiss != null ? rec.cacheMiss : rec.prompt;
  const value = (hit / 1e6) * (price.inputHit || 0)
    + (miss / 1e6) * (price.inputMiss || 0)
    + (rec.completion / 1e6) * (price.output || 0);
  return Math.round(value * 1e6) / 1e6;
}

function costSummary() {
  // 还没有请求时，只要价格表里有模型就算"能算成本"（金额为 0），避免误报"价格表未收录"
  const hasPrice = Object.keys(pricingTable || {}).length > 0;
  const known = state.totals.requests === 0 ? hasPrice : !!state.totals.costKnown;
  return {
    // 便宜模型（如 flash 空闲时段）单次成本极小，保留 6 位小数避免被抹成 0
    total: Math.round(state.totals.cost * 1e6) / 1e6,
    known,
    currency: config.currency || '',
    pricingIsBuiltin: pricingMeta.label === '内置官方价'
  };
}

/* ------------------------------------------------------------------ *
 * 账户余额
 * ------------------------------------------------------------------ */

const balance = { data: null, error: null, fetchedAt: 0, loading: false, keySource: null, keyMasked: null };
let lastAuthHeader = null;

function resolveApiKey() {
  if (config.apiKey) return { header: 'Bearer ' + config.apiKey, source: 'config.json' };
  const envName = config.apiKeyEnv;
  if (envName && process.env[envName]) return { header: 'Bearer ' + process.env[envName], source: '环境变量 ' + envName };
  if (lastAuthHeader) return { header: lastAuthHeader, source: '最近一次请求携带的 Key' };
  return null;
}

function maskKey(header) {
  const token = String(header || '').replace(/^Bearer\s+/i, '').trim();
  if (token.length <= 10) return token.slice(0, 3) + '****';
  return token.slice(0, 6) + '****' + token.slice(-4);
}

function balanceSnapshot() {
  return {
    ok: !balance.error,
    fetchedAt: balance.fetchedAt || null,
    loading: !!balance.loading,
    refreshSeconds: config.balanceRefreshSeconds,
    keySource: balance.keySource,
    keyMasked: balance.keyMasked,
    error: balance.error,
    isAvailable: balance.data ? balance.data.isAvailable : null,
    balances: balance.data ? balance.data.balances : []
  };
}

/** 查询余额，结果带缓存；force = true 时忽略缓存。done 在结束后调用。 */
function refreshBalance(force, done) {
  const finish = () => { if (typeof done === 'function') done(); };
  const intervalMs = Math.max(5, config.balanceRefreshSeconds || 120) * 1000;
  if (balance.loading) return finish();
  if (!force && balance.fetchedAt && Date.now() - balance.fetchedAt < intervalMs) return finish();

  const auth = resolveApiKey();
  if (!auth) {
    balance.error = '还没有可用的 API Key：先发一次请求，或在 config.json 填 apiKey / 设置环境变量';
    balance.data = null;
    balance.fetchedAt = Date.now();
    return finish();
  }

  let base;
  try { base = new URL(config.upstream); } catch {
    balance.error = '上游地址无法解析';
    balance.fetchedAt = Date.now();
    return finish();
  }

  const transport = base.protocol === 'https:' ? https : http;
  balance.loading = true;
  const req = transport.request({
    protocol: base.protocol,
    hostname: base.hostname,
    port: base.port || (base.protocol === 'https:' ? 443 : 80),
    path: config.balancePath || '/user/balance',
    method: 'GET',
    headers: { authorization: auth.header, accept: 'application/json' },
    timeout: 15000
  }, (res) => {
    let text = '';
    res.on('data', (c) => { text += c.toString('utf8'); });
    res.on('end', () => {
      balance.loading = false;
      balance.fetchedAt = Date.now();
      balance.keySource = auth.source;
      balance.keyMasked = maskKey(auth.header);
      if (res.statusCode !== 200) {
        balance.data = null;
        balance.error = (res.statusCode === 401 || res.statusCode === 403)
          ? 'Key 被拒绝（HTTP ' + res.statusCode + '）'
          : (res.statusCode === 404 ? '该上游没有余额接口（HTTP 404）' : '查询失败 HTTP ' + res.statusCode);
        pushSnapshot();
        return finish();
      }
      try {
        const json = JSON.parse(text);
        const infos = Array.isArray(json.balance_infos) ? json.balance_infos : [];
        balance.data = {
          isAvailable: !!json.is_available,
          balances: infos.map((b) => ({
            currency: b.currency,
            total: b.total_balance,
            granted: b.granted_balance,
            toppedUp: b.topped_up_balance
          }))
        };
        balance.error = infos.length ? null : '上游没有返回余额明细';
      } catch (err) {
        balance.data = null;
        balance.error = '余额响应解析失败：' + err.message;
      }
      pushSnapshot();
      finish();
    });
  });
  req.on('timeout', () => req.destroy(new Error('余额查询超时')));
  req.on('error', (err) => {
    balance.loading = false;
    balance.fetchedAt = Date.now();
    balance.data = null;
    balance.error = '余额查询失败：' + err.message;
    finish();
  });
  req.end();
}

/* ------------------------------------------------------------------ *
 * DSH 会话用量
 *
 * DSH 把每个会话的 token 用量投影缓存在
 *   ~/.dsh/storages/session_projcache/sessions/session-*.json
 * 的 record.rows.tokenUsage.val.totals 里。启动时读一次，就能看到
 * 「不经过本代理」的那部分用量（比如你正在用的 DSH 对话本身）。
 * ------------------------------------------------------------------ */

const DSH_USAGE_FIELDS = ['uncachedInputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'outputTokens'];

const dshUsage = {
  sessions: [],
  totals: null,
  today: null,
  fetchedAt: null,
  error: null,
  dir: ''
};

// ── 本轮对话 ────────────────────────────────────────────────────────────
// DSH 每轮对话对应一个会话投影文件 session-<id>.json，里面带 title 和 tokenUsage。
// 「本轮对话」= 最近有更新的那个文件（也就是你正在看的这轮）。
// 会话文件会随对话实时更新，所以这里按 mtime 缓存：文件没变就不重读、不重算。
const currentSession = {
  path: '',
  mtime: 0,
  id: '',
  title: '',
  cwd: '',
  tokens: null,
  peak: false,
  cost: null
};

function emptyDshTotals() {
  const t = {};
  for (const f of DSH_USAGE_FIELDS) t[f] = 0;
  t.total = 0;
  return t;
}

function dshUsageDir() {
  if (config.dshUsageDir) return config.dshUsageDir;
  const home = process.env.USERPROFILE || process.env.HOME || '';
  return path.join(home, '.dsh', 'storages', 'session_projcache', 'sessions');
}

function dayKeyLocal(ts) {
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 启动时读一次：扫描会话投影缓存，汇总 tokenUsage。 */
function readDshUsage() {
  dshUsage.fetchedAt = Date.now();
  if (config.includeDshUsage === false) {
    dshUsage.error = null;
    dshUsage.sessions = [];
    dshUsage.totals = null;
    dshUsage.today = null;
    return;
  }
  const dir = dshUsageDir();
  dshUsage.dir = dir;
  const totals = emptyDshTotals();
  const today = emptyDshTotals();
  const todayKey = dayKeyLocal(Date.now());
  const sessions = [];
  try {
    if (!fs.existsSync(dir)) {
      dshUsage.error = '找不到 DSH 会话缓存目录（' + dir + '）';
      dshUsage.sessions = [];
      dshUsage.totals = null;
      dshUsage.today = null;
      return;
    }
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      const full = path.join(dir, name);
      let doc;
      let mtime;
      try {
        mtime = fs.statSync(full).mtimeMs;
        doc = readJsonFile(full);
      } catch { continue; }
      const raw = doc && doc.record && doc.record.rows && doc.record.rows.tokenUsage
        && doc.record.rows.tokenUsage.val && doc.record.rows.tokenUsage.val.totals;
      if (!raw) continue;
      const one = emptyDshTotals();
      for (const f of DSH_USAGE_FIELDS) {
        const v = Number(raw[f]);
        if (Number.isFinite(v)) { one[f] = v; one.total += v; }
      }
      if (one.total <= 0) continue;
      const isToday = dayKeyLocal(mtime) === todayKey;
      sessions.push({
        id: name.replace(/^session-/, '').replace(/\.json$/, ''),
        modifiedAt: mtime,
        isToday,
        tokens: one
      });
      for (const f of DSH_USAGE_FIELDS) totals[f] += one[f];
      totals.total += one.total;
      if (isToday) {
        for (const f of DSH_USAGE_FIELDS) today[f] += one[f];
        today.total += one.total;
      }
    }
    sessions.sort((a, b) => b.modifiedAt - a.modifiedAt);
    dshUsage.sessions = sessions;
    dshUsage.totals = totals;
    dshUsage.today = today;
    dshUsage.error = null;
    if (sessions.length) {
      console.log(`[dsh] 已读取 ${sessions.length} 个 DSH 会话的用量：合计 ${totals.total} tok（今日 ${today.total}）`);
    }
  } catch (err) {
    dshUsage.error = '读取 DSH 会话用量失败：' + err.message;
    dshUsage.sessions = [];
    dshUsage.totals = null;
    dshUsage.today = null;
  }
}

/**
 * 取「本轮对话」的用量与花费。
 * 会话 token 的分类正好对应定价口径：
 *   cacheReadTokens      → 命中缓存的输入（inputHit）
 *   uncachedInputTokens  → 未命中缓存的输入（inputMiss）
 *   cacheWriteTokens     → 也按未命中输入计价（官方没有单独的写回价）
 *   outputTokens         → 输出
 * 花费按「当前时段」的价计算，所以高峰/空闲切换时这个数字会跟着变（这是当前价，不是历史账单）。
 */
function computeConversationCost(tokens, peak) {
  const model = (state.last && state.last.model) || Object.keys(pricingTable)[0];
  const price = model ? effectivePrice(model, peak) : null;
  if (!price || !tokens) return null;
  const hit = tokens.cacheReadTokens || 0;
  const miss = (tokens.uncachedInputTokens || 0) + (tokens.cacheWriteTokens || 0);
  const value = (hit / 1e6) * (price.inputHit || 0)
    + (miss / 1e6) * (price.inputMiss || 0)
    + ((tokens.outputTokens || 0) / 1e6) * (price.output || 0);
  return {
    value: Math.round(value * 1e6) / 1e6,
    model: price.model,
    inputHit: price.inputHit,
    inputMiss: price.inputMiss,
    output: price.output
  };
}

/** 找到最近更新的会话文件并读出来；文件没变就直接用缓存，不重复读盘。 */
function updateCurrentSession() {
  if (config.includeDshUsage === false) return;
  const dir = dshUsageDir();
  let newest = null;
  let newestMtime = 0;
  try {
    if (!fs.existsSync(dir)) return;
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      const full = path.join(dir, name);
      let st;
      try { st = fs.statSync(full); } catch { continue; }
      if (st.mtimeMs > newestMtime) { newestMtime = st.mtimeMs; newest = full; }
    }
  } catch { return; }
  if (!newest) return;
  if (newest === currentSession.path && newestMtime === currentSession.mtime) return;  // 没变，用缓存

  const next = {
    path: newest,
    mtime: newestMtime,
    id: path.basename(newest).replace(/^session-/, '').replace(/\.json$/, ''),
    title: '',
    cwd: '',
    tokens: emptyDshTotals(),
    peak: isPeakNow(),
    cost: null
  };
  try {
    const doc = readJsonFile(newest);
    const rows = (doc && doc.record && doc.record.rows) || {};
    if (rows.title && rows.title.val) next.title = String(rows.title.val);
    if (doc && doc.record && doc.record.identity && doc.record.identity.cwd) next.cwd = String(doc.record.identity.cwd);
    const raw = rows.tokenUsage && rows.tokenUsage.val && rows.tokenUsage.val.totals;
    if (raw) {
      for (const f of DSH_USAGE_FIELDS) {
        const v = Number(raw[f]);
        if (Number.isFinite(v)) { next.tokens[f] = v; next.tokens.total += v; }
      }
    }
    next.cost = computeConversationCost(next.tokens, next.peak);
  } catch {
    // 读不到就保留上一次的值，不要让界面闪成 0
    return;
  }
  currentSession.path = next.path;
  currentSession.mtime = next.mtime;
  currentSession.id = next.id;
  currentSession.title = next.title;
  currentSession.cwd = next.cwd;
  currentSession.tokens = next.tokens;
  currentSession.peak = next.peak;
  currentSession.cost = next.cost;
}

function conversationSnapshot() {
  if (config.includeDshUsage === false) {
    return { ok: false, enabled: false, error: '已在 config.json 里关掉 includeDshUsage' };
  }
  if (!currentSession.path || !currentSession.tokens) {
    return { ok: false, enabled: true, error: dshUsage.error || '还没读到 DSH 会话', title: '', id: '' };
  }
  return {
    ok: true,
    enabled: true,
    id: currentSession.id,
    title: currentSession.title,
    cwd: currentSession.cwd,
    modifiedAt: currentSession.mtime,
    tokens: currentSession.tokens,
    cost: currentSession.cost ? currentSession.cost.value : null,
    costCurrency: config.currency || '¥',
    costModel: currentSession.cost ? currentSession.cost.model : '',
    costPeak: currentSession.peak,
    costPrice: currentSession.cost
  };
}

function dshUsageSnapshot() {
  return {
    ok: !dshUsage.error,
    enabled: config.includeDshUsage !== false,
    dir: dshUsage.dir || dshUsageDir(),
    fetchedAt: dshUsage.fetchedAt,
    error: dshUsage.error,
    sessionCount: dshUsage.sessions.length,
    sessions: dshUsage.sessions.slice(0, 10),
    totals: dshUsage.totals,
    today: dshUsage.today,
    fields: DSH_USAGE_FIELDS
  };
}

/* ------------------------------------------------------------------ *
 * 对外快照
 * ------------------------------------------------------------------ */

const broadcasters = new Set();

function snapshot() {
  const today = state.byDay.get(dayKey(Date.now())) || Object.assign(EMPTY_BUCKET(), { key: dayKey(Date.now()) });
  // 还没有任何请求时，用价格表里的第一个模型展示单价，避免刚启动就看到"未收录"
  const priceModel = state.last ? state.last.model : Object.keys(pricingTable)[0];
  const peak = peakInfo();
  const price = priceModel ? effectivePrice(priceModel, peak.peak) : null;
  updateCurrentSession();      // 顺手刷新"本轮对话"（文件没变就用缓存，不读盘）
  return {
    ok: true,
    mock: !!config.mock,
    upstream: config.upstream,
    startedAt: state.startedAt,
    uptimeMs: Date.now() - state.startedAt,
    totals: state.totals,
    today,
    byModel: [...state.byModel.values()].sort((a, b) => b.total - a.total),
    byDay: [...state.byDay.values()].sort((a, b) => (a.key < b.key ? 1 : -1)).slice(0, 14),
    last: state.last,
    lastCost: state.last ? costOfRecord(state.last) : null,
    recent: state.recent.slice(-12).reverse(),
    rate: state.rate,
    cost: costSummary(),
    price,
    peakNow: peak.peak,
    // 为什么是高峰/空闲（界面提示与排查用）：周末 / 法定节假日 · 名称 / 工作日高峰时段 / 工作日非高峰时段
    peakReason: peak.reason,
    peakHoliday: peak.holiday,
    peakNextChangeAt: nextPeakChange(),
    // 当前时段的起点/终点/已过百分比（悬浮窗右下角的"还剩多久 + 已过 xx%" + 进度圆环用）
    peakWindow: peakWindow(),
    holidays: holidaySnapshot(),
    pricingIsBuiltin: pricingMeta.label === '内置官方价',
    pricingLabel: pricingMeta.label,
    pricingFetchedAt: pricingMeta.fetchedAt,
    pricingFetchedText: pricingFetchedText(),
    pricingNextRefreshAt: pricingMeta.nextRefreshAt,
    pricingError: pricingMeta.error,
    pricingSource: pricingMeta.url,
    balance: balanceSnapshot(),
    dshUsage: dshUsageSnapshot(),
    // 本轮对话（最近更新的那个 DSH 会话）的用量与花费，悬浮窗第 2 页显示这个
    conversation: conversationSnapshot(),
    // 经代理统计 + DSH 会话（两者目前互不重叠）= 界面上的"总用量"
    combined: {
      total: state.totals.total + (dshUsage.totals ? dshUsage.totals.total : 0),
      today: today.total + (dshUsage.today ? dshUsage.today.total : 0),
      proxyTotal: state.totals.total,
      proxyToday: today.total,
      dshTotal: dshUsage.totals ? dshUsage.totals.total : 0,
      dshToday: dshUsage.today ? dshUsage.today.total : 0
    }
  };
}

function pushSnapshot() {
  if (!broadcasters.size) return;
  const payload = `data: ${JSON.stringify(snapshot())}\n\n`;
  for (const res of broadcasters) {
    try { res.write(payload); } catch { broadcasters.delete(res); }
  }
}

/* ------------------------------------------------------------------ *
 * 记录一次请求
 * ------------------------------------------------------------------ */

function finishRecord(ctx) {
  // 非计费接口（如 GET /models）且上游也没给 usage 时，不写进统计
  if (!BILLABLE_PATH.test(ctx.path || '') && !ctx.usage) return null;
  const latencyMs = Math.max(1, Date.now() - ctx.t0);
  const usage = pickUsage(ctx.usage) || null;
  let prompt = usage ? usage.prompt : null;
  let completion = usage ? usage.completion : null;
  let estimated = false;

  if (config.estimateWhenMissing) {
    if (prompt === null) { prompt = estimateTokens(ctx.requestText); estimated = true; }
    if (completion === null) { completion = estimateTokens(ctx.responseText); estimated = true; }
  } else {
    prompt = prompt === null ? 0 : prompt;
    completion = completion === null ? 0 : completion;
  }

  const rec = {
    ts: Date.now(),
    model: ctx.model || '未知模型',
    prompt,
    completion,
    total: (usage && usage.total != null) ? usage.total : prompt + completion,
    cacheHit: usage && usage.hit != null ? usage.hit : null,
    cacheMiss: usage && usage.miss != null ? usage.miss : null,
    reasoning: usage && usage.reasoning != null ? usage.reasoning : null,
    peak: isPeakNow(),
    estimated,
    stream: !!ctx.stream,
    latencyMs,
    status: ctx.status,
    path: ctx.path,
    error: ctx.error || null
  };
  rec.cost = costOfRecord(rec);

  applyRecord(rec);
  persist(rec);
  pushSnapshot();

  const mark = estimated ? '~' : '';
  const costText = rec.cost == null ? '' : `  ¥${rec.cost.toFixed(6)}`;
  console.log(`[${new Date(rec.ts).toLocaleTimeString()}] ${rec.status} ${rec.model}  输入 ${mark}${rec.prompt} / 输出 ${mark}${rec.completion} / 合计 ${mark}${rec.total} (${latencyMs}ms)${costText}`);
  return rec;
}

/* ------------------------------------------------------------------ *
 * 转发到上游
 * ------------------------------------------------------------------ */

function readBody(req, cb) {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => cb(Buffer.concat(chunks)));
  req.on('error', () => cb(Buffer.alloc(0)));
}

function decompress(buf, encoding) {
  try {
    if (encoding === 'gzip') return zlib.gunzipSync(buf);
    if (encoding === 'deflate') return zlib.inflateSync(buf);
    if (encoding === 'br') return zlib.brotliDecompressSync(buf);
  } catch { /* 解不开就原样用 */ }
  return buf;
}

function forward(req, res, u) {
  // 记住客户端带来的 Key，余额查询在没有单独配置 key 时可以复用它
  if (req.headers.authorization) lastAuthHeader = req.headers.authorization;
  readBody(req, (rawBody) => {
    let body = rawBody;
    let parsed = null;
    if (body.length) {
      try { parsed = JSON.parse(body.toString('utf8')); } catch { /* 非 JSON，原样转发 */ }
    }
    if (parsed && config.injectUsage && parsed.stream === true && parsed.stream_options === undefined) {
      parsed.stream_options = { include_usage: true };
      body = Buffer.from(JSON.stringify(parsed), 'utf8');
    }

    const up = new URL(config.upstream);
    const basePath = up.pathname.replace(/\/+$/, '');
    let reqPath = u.pathname + u.search;
    if (basePath && reqPath.startsWith(basePath + '/')) reqPath = reqPath.slice(basePath.length);

    const headers = Object.assign({}, req.headers);
    delete headers.host;
    delete headers.connection;
    delete headers['content-length'];
    headers['accept-encoding'] = 'identity';
    if (body.length) headers['content-length'] = String(body.length);

    const ctx = {
      t0: Date.now(),
      model: (parsed && parsed.model) || null,
      stream: !!(parsed && parsed.stream),
      requestText: extractPromptText(parsed),
      responseText: '',
      usage: null,
      status: 0,
      path: u.pathname,
      error: null
    };

    const transport = up.protocol === 'https:' ? https : http;
    const options = {
      protocol: up.protocol,
      hostname: up.hostname,
      port: up.port || (up.protocol === 'https:' ? 443 : 80),
      path: (basePath + reqPath) || '/',
      method: req.method,
      headers,
      timeout: 300000
    };

    const upstreamReq = transport.request(options, (upstreamRes) => {
      ctx.status = upstreamRes.statusCode;
      const isSse = String(upstreamRes.headers['content-type'] || '').includes('text/event-stream');
      const outHeaders = Object.assign({}, upstreamRes.headers);
      res.writeHead(upstreamRes.statusCode, outHeaders);

      if (isSse) {
        let buffer = '';
        upstreamRes.on('data', (chunk) => {
          res.write(chunk);
          buffer += chunk.toString('utf8');
          let idx;
          while ((idx = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, idx).trim();
            buffer = buffer.slice(idx + 1);
            absorbSseLine(line, ctx);
          }
        });
        upstreamRes.on('end', () => {
          res.end();
          finishRecord(ctx);
        });
        upstreamRes.on('error', (err) => {
          ctx.error = err.message;
          try { res.end(); } catch { /* 已断开 */ }
          finishRecord(ctx);
        });
        return;
      }

      const chunks = [];
      upstreamRes.on('data', (c) => chunks.push(c));
      upstreamRes.on('end', () => {
        const raw = Buffer.concat(chunks);
        res.end(raw);
        const text = decompress(raw, upstreamRes.headers['content-encoding']).toString('utf8');
        try {
          const json = JSON.parse(text);
          const usage = pickUsage(json.usage);
          if (usage) ctx.usage = usage;
          if (json.model) ctx.model = json.model;
          ctx.responseText = extractResponseText(json);
          if (json.error) ctx.error = json.error.message || JSON.stringify(json.error);
        } catch {
          ctx.responseText = text.slice(0, 20000);
        }
        finishRecord(ctx);
      });
      upstreamRes.on('error', (err) => {
        ctx.error = err.message;
        try { res.end(); } catch { /* 已断开 */ }
        finishRecord(ctx);
      });
    });

    upstreamReq.on('timeout', () => {
      upstreamReq.destroy(new Error('上游响应超时'));
    });
    upstreamReq.on('error', (err) => {
      ctx.error = err.message;
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json; charset=utf-8' });
      }
      try { res.end(JSON.stringify({ error: { message: '代理转发失败：' + err.message } })); } catch { /* 已断开 */ }
      finishRecord(ctx);
    });

    if (body.length) upstreamReq.write(body);
    upstreamReq.end();
  });
}

function absorbSseLine(line, ctx) {
  if (!line.startsWith('data:')) return;
  const payload = line.slice(5).trim();
  if (!payload || payload === '[DONE]') return;
  let obj;
  try { obj = JSON.parse(payload); } catch { return; }
  if (obj.usage) ctx.usage = pickUsage(obj.usage) || ctx.usage;
  if (obj.model) ctx.model = obj.model;
  const choice = Array.isArray(obj.choices) ? obj.choices[0] : null;
  const delta = choice && (choice.delta || choice.message);
  if (delta && typeof delta.content === 'string') ctx.responseText += delta.content;
}

/* ------------------------------------------------------------------ *
 * mock 上游：不联网也能验证统计链路
 * ------------------------------------------------------------------ */

function mockHandler(req, res, u) {
  const t0 = Date.now();
  readBody(req, (raw) => {
    let parsed = {};
    try { parsed = JSON.parse(raw.toString('utf8')); } catch { /* 空请求体 */ }
    const promptText = extractPromptText(parsed);
    const promptTokens = estimateTokens(promptText);
    const answer = '这是模拟响应，用来验证 token 统计链路是否正常。路径 ' + u.pathname;
    const completionTokens = estimateTokens(answer);
    const model = parsed.model || 'mock-model';
    const hitTokens = Math.floor(promptTokens * 0.3);
    const usage = {
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      total_tokens: promptTokens + completionTokens,
      prompt_cache_hit_tokens: hitTokens,
      prompt_cache_miss_tokens: promptTokens - hitTokens,
      completion_tokens_details: { reasoning_tokens: 0 }
    };
    const ctx = { t0, model, stream: !!parsed.stream, requestText: promptText, responseText: answer, usage, status: 200, path: u.pathname, error: null };

    if (parsed.stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache' });
      const pieces = answer.match(/.{1,4}/gs) || [answer];
      let i = 0;
      const tick = () => {
        if (i < pieces.length) {
          res.write(`data: ${JSON.stringify({ object: 'chat.completion.chunk', model, choices: [{ index: 0, delta: { content: pieces[i++] } }] })}\n\n`);
          setTimeout(tick, 25);
          return;
        }
        res.write(`data: ${JSON.stringify({ object: 'chat.completion.chunk', model, choices: [], usage })}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
        finishRecord(ctx);
      };
      tick();
      return;
    }

    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      object: 'chat.completion',
      model,
      choices: [{ index: 0, message: { role: 'assistant', content: answer }, finish_reason: 'stop' }],
      usage
    }));
    finishRecord(ctx);
  });
}

/* ------------------------------------------------------------------ *
 * HTTP 服务
 * ------------------------------------------------------------------ */

function sendJson(res, obj, code) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code || 200, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length, 'cache-control': 'no-store' });
  res.end(body);
}

function sendHtml(res, html) {
  const body = Buffer.from(html, 'utf8');
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  const p = u.pathname;

  if (p === '/__stats') {
    // 顺手按需刷新余额（有缓存间隔保护，不会频繁请求上游）
    refreshBalance(false);
    return sendJson(res, snapshot());
  }
  if (p === '/__balance') {
    return refreshBalance(u.searchParams.get('force') === '1', () => sendJson(res, balanceSnapshot()));
  }
  if (p === '/__pricing') return sendJson(res, pricingSnapshot());
  if (p === '/__pricing/refresh') {
    return refreshPricing(true, () => sendJson(res, pricingSnapshot()));
  }
  if (p === '/__holidays') return sendJson(res, holidaySnapshot());
  if (p === '/__holidays/refresh') {
    return refreshHolidays(true, () => sendJson(res, holidaySnapshot()));
  }
  // 现在的时段（高峰/空闲）与原因，可直接 curl 核对；
  // 带 ?at=<毫秒/秒时间戳或 ISO 时间> 可以问"某个时刻算高峰还是空闲"（用于核对节假日/周末/工作日边界）
  if (p === '/__peak') {
    const at = u.searchParams.get('at');
    let ts = Date.now();
    if (at) {
      if (/^\d{13}$/.test(at)) ts = Number(at);
      else if (/^\d{10}$/.test(at)) ts = Number(at) * 1000;
      else ts = Date.parse(at);
      if (!Number.isFinite(ts)) return sendJson(res, { ok: false, error: '无法解析 at 参数：' + at }, 400);
    }
    const info = peakInfo(ts);
    const beijing = (t) => new Date(t + 8 * 3600 * 1000).toISOString().replace('T', ' ').slice(0, 19);
    const next = nextPeakChange(ts);
    return sendJson(res, {
      ok: true,
      checkedAt: ts,
      beijingTime: beijing(ts) + '（北京时间）',
      peak: info.peak,
      tierText: info.peak ? '高峰' : '空闲',
      reason: info.reason,
      holiday: info.holiday,
      nextChangeAt: next,
      nextChangeBeijing: next ? beijing(next) + '（' + (peakInfo(next).peak ? '转高峰' : '转空闲') + '）' : null,
      // 当前时段的起点/终点/已过百分比（与 /__stats 的 peakWindow 同源，便于直接核对）
      window: peakWindow(ts),
      now: { beijingTime: beijing(Date.now()) + '（北京时间）', peak: isPeakNow(), reason: peakInfo().reason },
      holidays: holidaySnapshot()
    });
  }
  if (p === '/__dsh-usage') return sendJson(res, dshUsageSnapshot());
  if (p === '/__dsh-usage/refresh') {
    readDshUsage();
    currentSession.path = '';      // 强制下次重新定位/重读"本轮对话"
    updateCurrentSession();
    pushSnapshot();
    return sendJson(res, dshUsageSnapshot());
  }
  if (p === '/__conversation') return sendJson(res, conversationSnapshot());
  if (p === '/__conversation/refresh') {
    currentSession.path = '';
    updateCurrentSession();
    pushSnapshot();
    return sendJson(res, conversationSnapshot());
  }
  if (p === '/__health') return sendJson(res, { ok: true, uptimeMs: Date.now() - state.startedAt });
  if (p === '/__reset' && req.method === 'POST') {
    state.totals = Object.assign(EMPTY_BUCKET(), { estimated: 0 });
    state.byModel = new Map();
    state.byDay = new Map();
    state.recent = [];
    state.last = null;
    state.rate = { completionPerSec: 0, latencyMs: 0 };
    fs.writeFileSync(USAGE_LOG, '', 'utf8');
    pushSnapshot();
    console.log('[reset] 统计已清零');
    return sendJson(res, { ok: true });
  }
  if (p === '/__stats/stream') {
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify(snapshot())}\n\n`);
    broadcasters.add(res);
    req.on('close', () => broadcasters.delete(res));
    return;
  }
  if (p === '/__dashboard' || p === '/') {
    if (fs.existsSync(DASHBOARD_FILE)) return sendHtml(res, fs.readFileSync(DASHBOARD_FILE, 'utf8'));
    return sendHtml(res, '<h1>token-monitor</h1><p>dashboard.html 缺失，可直接访问 /__stats</p>');
  }

  if (config.mock) return mockHandler(req, res, u);
  return forward(req, res, u);
});

/* ------------------------------------------------------------------ *
 * 启动
 * ------------------------------------------------------------------ */

if (hasFlag('--reset')) {
  fs.writeFileSync(USAGE_LOG, '', 'utf8');
  console.log('[reset] 已清空 data/usage.jsonl');
  process.exit(0);
}

// 只要新价格、不启动服务： node proxy.js --refresh-pricing
if (hasFlag('--refresh-pricing')) {
  loadPricingCache();
  buildPricingTable();
  refreshPricing(true, () => {
    console.log(JSON.stringify(pricingSnapshot(), null, 2));
    process.exit(pricingMeta.error ? 1 : 0);
  });
  return;
}

// 只更新节假日表、不启动服务： node proxy.js --refresh-holidays
if (hasFlag('--refresh-holidays')) {
  loadHolidayCache();
  refreshHolidays(true, () => {
    console.log(JSON.stringify(holidaySnapshot(), null, 2));
    process.exit(holidayMeta.error ? 1 : 0);
  });
  return;
}

loadPricingCache();
buildPricingTable();
refreshPricing(false);        // 缓存超过 7 天（或还没有缓存）时后台自动更新
schedulePricingRefresh();

loadHolidayCache();
refreshHolidays(false);       // 缓存过期或还没有缓存时后台自动更新（失败继续用内置表）
scheduleHolidayRefresh();

readDshUsage();               // 启动时读一次 DSH 会话自身的 token 用量
replayHistory();

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[error] 端口 ${config.port} 已被占用。可能代理已经在运行，或修改 config.json 里的 port。`);
  } else {
    console.error('[error] ' + err.message);
  }
  process.exit(1);
});

server.listen(config.port, config.host, () => {
  fs.writeFileSync(path.join(DATA_DIR, 'proxy.pid'), String(process.pid), 'utf8');
  console.log('──────────────────────────────────────────────');
  console.log(' token-monitor 已启动');
  console.log(`   监听地址   http://${config.host}:${config.port}`);
  console.log(`   上游地址   ${config.mock ? '(mock 模式，不访问上游)' : config.upstream}`);
  console.log(`   统计接口   http://${config.host}:${config.port}/__stats`);
  console.log(`   余额接口   http://${config.host}:${config.port}/__balance`);
  console.log(`   网页面板   http://${config.host}:${config.port}/__dashboard`);
  const peak = peakInfo();
  console.log(`   价格来源   ${pricingMeta.label}${pricingFetchedText() ? '（' + pricingFetchedText() + '）' : ''}`);
  console.log(`   当前时段   ${peak.peak ? '高峰时段' : '空闲时段'}（${peak.reason}）`);
  console.log(`   价格接口   http://${config.host}:${config.port}/__pricing（自动更新：每 ${refreshDays()} 天）`);
  console.log(`   节假日表   ${holidayMeta.label}（自动更新：每 ${Number(config.holidaysRefreshDays) > 0 ? Number(config.holidaysRefreshDays) : 30} 天）`);
  console.log(`   用法提示   把你的程序 base_url 改成 http://${config.host}:${config.port}`);
  console.log('──────────────────────────────────────────────');
  if (hasFlag('--widget') || config.autoStartWidget) startWidget();
});

function startWidget() {
  if (process.platform !== 'win32') {
    console.log('[widget] 悬浮窗目前只支持 Windows，跳过。');
    return;
  }
  const script = path.join(ROOT, 'widget.ps1');
  if (!fs.existsSync(script)) {
    console.log('[widget] 找不到 widget.ps1，跳过。');
    return;
  }
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-Port', String(config.port)], {
    detached: true,
    stdio: 'ignore',
    windowsHide: false
  });
  child.unref();
  console.log('[widget] 已拉起桌面悬浮窗');
}

process.on('SIGINT', () => {
  console.log('\n[exit] 代理已停止');
  process.exit(0);
});
