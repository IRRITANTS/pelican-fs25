// Minimal FS25 web admin client: "start" presses Start with the values the web admin shows,
// "stop" presses Stop. Never prints credentials or cookies.
// Uses node:http: the FS25 web server rejects fetch() requests (headers and body
// arrive in separate packets), while http.request sends them together via req.end(body).
import http from 'node:http';

const host = `${process.env.WEBSERVER_LISTENING_ON}:${process.env.WEB_PORT || '7999'}`;
const base = `http://${host}/index.html?lang=en`;
const form = (data) => new URLSearchParams(data).toString();

function request(method, cookie = '', data = null) {
  const body = data ? form(data) : '';
  const headers = { Connection: 'close' };
  if (cookie) headers.Cookie = cookie;
  if (data) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  return new Promise((resolve, reject) => {
    const req = http.request(base, { method, headers, agent: false }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { text += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, cookies: res.headers['set-cookie'] || [], text }));
    });
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end(body);
  });
}

async function login() {
  const res = await request('POST', '', {
    username: process.env.WEB_USERNAME, password: process.env.WEB_PASSWORD, login: 'Login',
  });
  for (const c of res.cookies) {
    const m = /(SessionID=[^;]+)/i.exec(c);
    if (m) return m[1];
  }
  throw new Error(`login failed (HTTP ${res.status}), check WEB_USERNAME / WEB_PASSWORD`);
}

async function page(cookie) {
  return (await request('GET', cookie)).text;
}

async function post(cookie, data) {
  return (await request('POST', cookie, data)).status;
}

const startParams = [
  'game_name', 'admin_password', 'game_password', 'savegame', 'server_port', 'max_player',
  'mp_language', 'auto_save_interval', 'stats_interval', 'pause_game_if_empty',
];

const unescape = (s) => s.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, '&');

function formValues(html) {
  const out = {};
  for (const m of html.matchAll(/<input type="[^"]*" name="([^"]*)" value="([^"]*)"/gi)) out[m[1]] = unescape(m[2]);
  for (const m of html.matchAll(/<select name\s*=\s*"([^"]*)".*?<option value="([^"]*)" selected="selected"/gisu)) {
    out[m[1]] = unescape(m[2]);
  }
  return out;
}

async function start() {
  const cookie = await login();
  console.log('logged in');
  let html = await page(cookie);
  if (/name="stop_server"/i.test(html)) {
    console.log('game is already running');
    return;
  }
  // mods and DLC are switched on with the separate "Activate Mods" form: the save-on-stop helper mod
  // (PELICAN_MOD) and the DLC chosen by SERVER_DLC (all | none | list); everything else stays as set by hand
  const inactive = [...html.matchAll(/name="modactivate_([^"]+)"/gi)].map((m) => unescape(m[1]));
  const wanted = new Set();
  if (process.env.PELICAN_MOD) wanted.add(process.env.PELICAN_MOD);
  const dlcSetting = (process.env.SERVER_DLC || 'none').trim();
  const dlcName = (s) => s.trim().replace(/^pdlc_/i, '').replace(/\.dlc$/i, '').toLowerCase();
  const dlcList = dlcSetting.split(',').map(dlcName).filter(Boolean);
  for (const file of inactive.filter((f) => /\.dlc$/i.test(f))) {
    if (dlcSetting.toLowerCase() === 'all' || dlcList.includes(dlcName(file))) wanted.add(file);
  }
  const toActivate = inactive.filter((f) => wanted.has(f));
  if (toActivate.length) {
    const form = { activate_mods: 'Activate' };
    for (const f of toActivate) form[`modactivate_${f}`] = 'on';
    const status = await post(cookie, form);
    html = await page(cookie);
    const still = toActivate.filter((f) => html.includes(`name="modactivate_${f}"`));
    console.log(`activated: ${toActivate.join(', ')} (HTTP ${status})${still.length ? `; still inactive: ${still.join(', ')}` : ''}`);
  }
  const values = formValues(html);
  const data = {};
  for (const key of startParams) {
    if (values[key] === undefined) throw new Error(`start form has no field "${key}"`);
    data[key] = values[key];
  }
  const crossplay = /<input type="checkbox" name="crossplay_allowed" checked="checked"/i.test(html);
  data.crossplay_allowed = crossplay ? 'on' : 'off';
  data.start_server = 'Start';
  const active = [...html.matchAll(/name="moddeactivate_([^"]+)"/gi)].map((m) => unescape(m[1]));
  console.log(`pressing Start (savegame ${data.savegame}, port ${data.server_port}, slots ${data.max_player}, active mods: ${active.join(', ') || 'none'})`);
  console.log(`start requested (HTTP ${await post(cookie, data)})`);
}

async function stop() {
  const cookie = await login();
  const html = await page(cookie);
  const button = /<input[^>]*name="(stop_server)"[^>]*value="([^"]*)"/i.exec(html);
  if (!button) {
    console.log('stop button not found in web admin (game not running?)');
    return;
  }
  console.log(`stop requested (HTTP ${await post(cookie, { [button[1]]: button[2] })})`);
}

const commands = { start, stop };
const cmd = commands[process.argv[2]];
if (!cmd) {
  console.log('usage: fs25-webadmin.mjs start|stop');
  process.exit(2);
}
cmd().catch((e) => {
  console.log(`error: ${e.message}`);
  process.exit(1);
});
