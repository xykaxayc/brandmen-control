// Минимальный приёмник логов для Brandmen Control.
// Принимает POST /logs?site=...&version=...&ts=... с текстом лога в теле и
// сохраняет в файл logs/<site>/<время>.log. Если задан LOG_TOKEN — требует
// заголовок Authorization: Bearer <LOG_TOKEN>.
//
// Запуск:  LOG_TOKEN=секрет node server.js
// HTTPS обеспечивается реверс-прокси (Caddy/nginx) — см. README.

const express = require('express');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8787;
const TOKEN = process.env.LOG_TOKEN || ''; // пусто = без проверки токена
const DIR = process.env.LOG_DIR || path.join(__dirname, 'logs');
fs.mkdirSync(DIR, { recursive: true });

const app = express();
app.use(express.text({ type: '*/*', limit: '25mb' }));

const safe = (s) => (s || '').toString().replace(/[^a-zA-Z0-9._-]/g, '_');

app.post('/logs', (req, res) => {
  if (TOKEN) {
    if ((req.get('authorization') || '') !== `Bearer ${TOKEN}`) {
      return res.status(401).send('unauthorized');
    }
  }
  const site = safe(req.query.site) || 'unknown';
  const version = safe(req.query.version);
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const dir = path.join(DIR, site);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${ts}.log`);
  fs.writeFileSync(file, req.body || '', 'utf8');
  const bytes = Buffer.byteLength(req.body || '', 'utf8');
  console.log(`[${new Date().toISOString()}] ${site} v${version} -> ${file} (${bytes} b)`);
  res.send(`ok: ${site}/${ts}.log`);
});

app.get('/', (_req, res) => res.send('brandmen log server'));
app.listen(PORT, () => console.log(`log server on :${PORT}, dir=${DIR}`));
