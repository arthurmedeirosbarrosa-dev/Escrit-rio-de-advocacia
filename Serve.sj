const express = require('express');
const session = require('express-session');
const pgSession = require('connect-pg-simple')(session);
const { Pool } = require('pg');
const passport = require('passport');
const { Strategy } = require('passport-google-oauth20');

const NOME = process.env.NOME_ESCRITORIO || 'Meu Escritório';
const ADMINS = (process.env.ADMIN_EMAILS || 'arthurmedeirosbarrosa@gmail.com')
  .split(',').map(e => e.trim().toLowerCase()).filter(Boolean);
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.PGSSL === 'true' ? { rejectUnauthorized: false } : false,
});

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const adminsDb = new Set();
const isAdmin = u => !!u && (ADMINS.includes(u.email) || adminsDb.has(u.email));
const fmt = d => new Date(d).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' });

async function init() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS tickets (
      id SERIAL PRIMARY KEY, email TEXT NOT NULL, nome TEXT,
      problema TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'aberto',
      criado_em TIMESTAMPTZ NOT NULL DEFAULT now());
    CREATE TABLE IF NOT EXISTS mensagens (
      id SERIAL PRIMARY KEY, ticket_id INT NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
      autor_email TEXT NOT NULL, autor_nome TEXT, admin BOOLEAN NOT NULL DEFAULT false,
      texto TEXT NOT NULL, criado_em TIMESTAMPTZ NOT NULL DEFAULT now());
    CREATE TABLE IF NOT EXISTS admins (
      email TEXT PRIMARY KEY, adicionado_por TEXT,
      criado_em TIMESTAMPTZ NOT NULL DEFAULT now());`);
  (await pool.query('SELECT email FROM admins')).rows.forEach(r => adminsDb.add(r.email));
}

passport.use(new Strategy({
  clientID: process.env.GOOGLE_CLIENT_ID,
  clientSecret: process.env.GOOGLE_CLIENT_SECRET,
  callbackURL: (process.env.BASE_URL || 'http://localhost:3000') + '/auth/google/callback',
}, (_a, _r, p, done) => done(null, { email: p.emails[0].value.toLowerCase(), nome: p.displayName })));
passport.serializeUser((u, d) => d(null, u));
passport.deserializeUser((u, d) => d(null, u));

const app = express();
app.set('trust proxy', 1);
app.use(express.urlencoded({ extended: false }));
app.use('/static', express.static('public'));
app.use(session({
  store: new pgSession({ pool, createTableIfMissing: true }),
  secret: process.env.SESSION_SECRET || 'troque-isto',
  resave: false, saveUninitialized: false,
  cookie: { maxAge: 30 * 864e5, httpOnly: true, sameSite: 'lax', secure: process.env.NODE_ENV === 'production' },
}));
app.use(passport.initialize());
app.use(passport.session());

function page(req, titulo, corpo) {
  const u = req.user;
  const links = [`<a href="/">Início</a>`];
  if (u) links.push(`<a href="/meus">Meus atendimentos</a>`);
  if (isAdmin(u)) links.push(`<a href="/admin">Painel dos administradores</a>`, `<a href="/admin/administradores">Gerenciar administradores</a>`);
  links.push(`<button id="tema" type="button"></button>`);
  links.push(u ? `<a href="/sair">Sair (${esc(u.email)})</a>` : `<a href="/auth/google">Entrar com Google</a>`);
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<script>document.documentElement.dataset.tema=localStorage.getItem('tema')||(matchMedia('(prefers-color-scheme:dark)').matches?'escuro':'claro')</script><title>${esc(titulo)} · ${esc(NOME)}</title><link rel="stylesheet" href="/static/style.css"></head><body>
<header><a class="marca" href="/">${esc(NOME)}</a>
<button id="menu-btn" aria-label="Abrir menu" aria-expanded="false"><span></span><span></span><span></span></button></header>
<nav id="menu" hidden>${links.join('')}</nav>
<main>${corpo}</main>
<script>const b=document.getElementById('menu-btn'),m=document.getElementById('menu');
b.onclick=()=>{m.hidden=!m.hidden;b.setAttribute('aria-expanded',!m.hidden)};
const t=document.getElementById('tema'),d=document.documentElement,rot=()=>t.textContent=d.dataset.tema==='escuro'?'Modo claro':'Modo escuro';rot();
t.onclick=()=>{const n=d.dataset.tema==='escuro'?'claro':'escuro';d.dataset.tema=n;localStorage.setItem('tema',n);rot()};</script></body></html>`;
}

const exigeLogin = (req, res, next) => req.user ? next() : res.redirect('/auth/google');
const exigeAdmin = (req, res, next) => isAdmin(req.user) ? next() : res.status(403).send(page(req, 'Acesso negado', '<h1>Acesso negado</h1><p>Esta página é só para administradores.</p>'));

async function criarTicket(u, problema) {
  const r = await pool.query('INSERT INTO tickets(email,nome,problema) VALUES($1,$2,$3) RETURNING id', [u.email, u.nome, problema]);
  return r.rows[0].id;
}

app.get('/', (req, res) => res.send(page(req, 'Início', req.user ? `
<h1>Conte brevemente o seu problema</h1>
<p>Responderemos por aqui, em privado.</p>
<form method="post" action="/enviar">
<label for="p">O que está acontecendo?</label>
<textarea id="p" name="problema" rows="7" maxlength="3000" required></textarea>
<button class="primario">Enviar</button></form>` : `
<h1>Entre com seu Gmail para começar</h1>
<p>Usamos o login do Google para que só você e o escritório vejam a sua conversa.</p>
<a class="botao" href="/auth/google">Entrar com Google</a>`)));

app.post('/enviar', exigeLogin, async (req, res) => {
  const problema = (req.body.problema || '').trim().slice(0, 3000);
  if (!problema) return res.redirect('/');
  res.redirect('/ticket/' + await criarTicket(req.user, problema));
});

app.get('/auth/google', passport.authenticate('google', { scope: ['profile', 'email'], keepSessionInfo: true }));
app.get('/auth/google/callback', passport.authenticate('google', { failureRedirect: '/', keepSessionInfo: true }), async (req, res) => {
  res.redirect(isAdmin(req.user) ? '/admin' : '/');
});
app.get('/sair', (req, res, next) => req.logout(e => e ? next(e) : res.redirect('/')));

const lista = rows => rows.length ? `<ul class="lista">${rows.map(t => `<li><a href="/ticket/${t.id}"><strong>#${t.id}</strong> ${esc(t.problema.slice(0, 90))}<small>${esc(t.nome || t.email)} · ${fmt(t.criado_em)} · ${t.status}</small></a></li>`).join('')}</ul>` : '<p>Nenhum atendimento ainda.</p>';

app.get('/meus', exigeLogin, async (req, res) => {
  const r = await pool.query('SELECT * FROM tickets WHERE email=$1 ORDER BY id DESC', [req.user.email]);
  res.send(page(req, 'Meus atendimentos', `<h1>Meus atendimentos</h1>${lista(r.rows)}<p><a href="/">Abrir novo atendimento</a></p>`));
});

app.get('/admin', exigeLogin, exigeAdmin, async (req, res) => {
  const r = await pool.query('SELECT * FROM tickets ORDER BY (status=\'aberto\') DESC, id DESC');
  res.send(page(req, 'Painel', `<h1>Tickets</h1>${lista(r.rows)}`));
});

const voltar = (res, msg) => res.redirect('/admin/administradores' + (msg ? '?erro=' + encodeURIComponent(msg) : ''));

app.get('/admin/administradores', exigeLogin, exigeAdmin, async (req, res) => {
  const r = await pool.query('SELECT * FROM admins ORDER BY criado_em');
  const fixos = ADMINS.map(e => `<li><span>${esc(e)}</span><small>principal</small></li>`).join('');
  const extras = r.rows.map(a => `<li><span>${esc(a.email)}</span><form method="post" action="/admin/administradores/remover"><input type="hidden" name="email" value="${esc(a.email)}"><button>Remover</button></form></li>`).join('');
  res.send(page(req, 'Administradores', `<h1>Administradores</h1>
${req.query.erro ? `<p class="erro">${esc(req.query.erro)}</p>` : ''}
<form method="post" action="/admin/administradores"><label for="e">Gmail da nova pessoa administradora</label>
<input id="e" type="email" name="email" placeholder="nome@gmail.com" required>
<button class="primario">Adicionar administrador</button></form>
<ul class="admins">${fixos}${extras}</ul>`));
});

app.post('/admin/administradores', exigeLogin, exigeAdmin, async (req, res) => {
  const email = (req.body.email || '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return voltar(res, 'Digite um e-mail válido.');
  if (isAdmin({ email })) return voltar(res, 'Essa pessoa já é administradora.');
  await pool.query('INSERT INTO admins(email, adicionado_por) VALUES($1,$2) ON CONFLICT DO NOTHING', [email, req.user.email]);
  adminsDb.add(email);
  voltar(res);
});

app.post('/admin/administradores/remover', exigeLogin, exigeAdmin, async (req, res) => {
  const email = (req.body.email || '').trim().toLowerCase();
  if (email === req.user.email) return voltar(res, 'Você não pode remover a si mesmo.');
  if (ADMINS.includes(email)) return voltar(res, 'Administradores principais só podem ser alterados no Render.');
  await pool.query('DELETE FROM admins WHERE email=$1', [email]);
  adminsDb.delete(email);
  voltar(res);
});

async function carregar(req, res) {
  const t = (await pool.query('SELECT * FROM tickets WHERE id=$1', [parseInt(req.params.id) || 0])).rows[0];
  if (!t || !(isAdmin(req.user) || t.email === req.user.email)) { res.status(404).send(page(req, 'Não encontrado', '<h1>Ticket não encontrado</h1>')); return null; }
  return t;
}

app.get('/ticket/:id', exigeLogin, async (req, res) => {
  const t = await carregar(req, res); if (!t) return;
  const ms = (await pool.query('SELECT * FROM mensagens WHERE ticket_id=$1 ORDER BY id', [t.id])).rows;
  const msgs = [{ admin: false, autor_nome: t.nome || t.email, texto: t.problema, criado_em: t.criado_em }, ...ms]
    .map(m => `<div class="msg ${m.admin ? 'adm' : 'cli'}"><b>${esc(m.admin ? m.autor_nome + ' (escritório)' : m.autor_nome)}</b><p>${esc(m.texto)}</p><small>${fmt(m.criado_em)}</small></div>`).join('');
  const fechar = isAdmin(req.user) ? `<form method="post" action="/ticket/${t.id}/status"><button>${t.status === 'aberto' ? 'Fechar ticket' : 'Reabrir ticket'}</button></form>` : '';
  res.send(page(req, 'Ticket #' + t.id, `<h1>Ticket #${t.id} <span class="tag">${t.status}</span></h1>${isAdmin(req.user) ? `<p>Cliente: ${esc(t.email)}</p>` : ''}
${msgs}${t.status === 'aberto' ? `<form method="post" action="/ticket/${t.id}/msg"><label for="m">Responder</label><textarea id="m" name="texto" rows="4" maxlength="3000" required></textarea><button class="primario">Enviar mensagem</button></form>` : '<p>Este ticket foi fechado.</p>'}${fechar}`));
});

app.post('/ticket/:id/msg', exigeLogin, async (req, res) => {
  const t = await carregar(req, res); if (!t) return;
  if (t.status !== 'aberto') return res.redirect('/ticket/' + t.id);
  const texto = (req.body.texto || '').trim().slice(0, 3000);
  if (texto) await pool.query('INSERT INTO mensagens(ticket_id,autor_email,autor_nome,admin,texto) VALUES($1,$2,$3,$4,$5)', [t.id, req.user.email, req.user.nome, isAdmin(req.user), texto]);
  res.redirect('/ticket/' + t.id);
});

app.post('/ticket/:id/status', exigeLogin, exigeAdmin, async (req, res) => {
  await pool.query("UPDATE tickets SET status = CASE WHEN status='aberto' THEN 'fechado' ELSE 'aberto' END WHERE id=$1", [parseInt(req.params.id) || 0]);
  res.redirect('/ticket/' + req.params.id);
});

init().then(() => app.listen(process.env.PORT || 3000, () => console.log('Rodando'))).catch(e => { console.error(e); process.exit(1); });
