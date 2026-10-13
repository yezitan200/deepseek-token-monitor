const http = require('http');

/**
 * 自测客户端：向本地代理发几次请求，验证统计链路。
 *   node test-client.js                 非流式 + 流式各一次
 *   node test-client.js --port 8788
 */

const argv = process.argv.slice(2);
const portIdx = argv.indexOf('--port');
const PORT = portIdx >= 0 && argv[portIdx + 1] ? parseInt(argv[portIdx + 1], 10) : 8788;

function request(payload) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload), 'utf8');
    const req = http.request({
      host: '127.0.0.1',
      port: PORT,
      path: '/v1/chat/completions',
      method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': body.length, authorization: 'Bearer test-key' }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c.toString('utf8'); });
      res.on('end', () => resolve({ status: res.statusCode, data }));
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function get(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c.toString('utf8'); });
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

(async () => {
  const messages = [
    { role: 'system', content: '你是一个简洁的助手。' },
    { role: 'user', content: '请用一句话说明什么是 token。' }
  ];

  console.log('→ 发送非流式请求…');
  const a = await request({ model: 'deepseek-flash', messages, max_tokens: 64 });
  console.log(`  HTTP ${a.status} 响应长度 ${a.data.length} 字节`);

  console.log('→ 发送流式请求…');
  const b = await request({ model: 'deepseek-flash', messages, stream: true, max_tokens: 64 });
  console.log(`  HTTP ${b.status} 收到 ${b.data.split('data:').length - 1} 个 SSE 数据块`);

  const stats = JSON.parse(await get('/__stats'));
  console.log('\n代理统计：');
  console.log(`  请求数     ${stats.totals.requests}`);
  console.log(`  输入 token ${stats.totals.prompt}（命中缓存 ${stats.last ? stats.last.cacheHit : '-'} / 未命中 ${stats.last ? stats.last.cacheMiss : '-'}）`);
  console.log(`  输出 token ${stats.totals.completion}`);
  console.log(`  合计 token ${stats.totals.total}`);
  console.log(`  按模型     ${stats.byModel.map((m) => `${m.key}=${m.total}`).join(', ')}`);
  if (stats.price) {
    const p = stats.price;
    console.log(`  当前价格   ${p.model} ${p.tierText}时段 输入(未命中) ${p.currency}${p.inputMiss} / 输入(命中) ${p.currency}${p.inputHit} / 输出 ${p.currency}${p.output} 每百万`);
  }
  console.log(`  本次成本   ${stats.lastCost == null ? '价格表未覆盖该模型' : stats.cost.currency + stats.lastCost}`);
  console.log(`  累计成本   ${stats.cost.known ? stats.cost.currency + stats.cost.total : '价格表未覆盖'}`);
  console.log(`  账户余额   ${stats.balance.error ? stats.balance.error : stats.balance.balances.map((b) => `${b.currency} ${b.total}`).join(' / ') || '（暂无）'}`);
  console.log(`  最近一次   ${JSON.stringify(stats.last)}`);

  const balance = JSON.parse(await get('/__balance?force=1'));
  console.log(`  余额接口   ${balance.error ? balance.error : balance.balances.map((b) => `${b.currency} 总 ${b.total}（赠金 ${b.granted} / 充值 ${b.toppedUp}）`).join('；') + ' [来源: ' + balance.keySource + ']'}`);

  // 余额要有可用 Key 才能查到，自测只要求统计与成本链路正确
  const ok = stats.totals.requests >= 2 && stats.totals.total > 0 && stats.byModel.length >= 1 && stats.lastCost != null;
  console.log(ok ? '\n结果：统计链路正常 ✔' : '\n结果：统计链路异常 ✘');
  process.exit(ok ? 0 : 1);
})().catch((err) => {
  console.error('自测失败：' + err.message);
  process.exit(1);
});
