/* Paddock — mode en ligne (Supabase). Chargé après l'appli. */
(function () {
  const CFG = window.PADDOCK_CONFIG || {};
  const SB = String(CFG.supabaseUrl || "").replace(/\/+$/, "");
  const KEY = CFG.supabaseKey || "";
  const SKEY = "paddock-session", PKEY = "paddock-prefs";
  let sess = null, syncing = false, lastSync = 0, lastPoll = 0;
  try { sess = JSON.parse(localStorage.getItem(SKEY) || "null"); } catch (e) {}

  const saveSess = () => { try { sess ? localStorage.setItem(SKEY, JSON.stringify(sess)) : localStorage.removeItem(SKEY); } catch (e) {} };
  const setSess = j => { sess = { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: j.expires_at || Math.floor(Date.now() / 1000) + (j.expires_in || 3600) }; saveSess(); };
  const T = s => s ? Date.parse(s) : 0;

  const FR = [
    [/invalid login credentials/i, "E-mail ou mot de passe incorrect."],
    [/user already registered|already been registered/i, "Un compte existe déjà avec cette adresse e-mail."],
    [/email not confirmed/i, "Confirmez votre adresse e-mail (lien reçu par e-mail) avant de vous connecter."],
    [/password should be at least/i, "Le mot de passe doit faire au moins 8 caractères."],
    [/rate limit|too many requests/i, "Trop de tentatives. Réessayez dans quelques minutes."],
    [/unable to validate email|invalid email/i, "Adresse e-mail invalide."],
    [/database error saving new user/i, "Ce pseudo est déjà pris ou invalide."],
    [/failed to fetch|networkerror|load failed/i, "Connexion impossible. Vérifiez votre réseau."]
  ];
  const frMsg = m => { for (const [re, f] of FR) if (re.test(m)) return f; return m; };

  async function http(method, path, body, useSession) {
    const h = { apikey: KEY, "Content-Type": "application/json", Authorization: "Bearer " + (useSession && sess ? sess.access_token : KEY) };
    let r;
    try { r = await fetch(SB + path, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) }); }
    catch (e) { throw new Error(frMsg(String(e.message || e))); }
    const txt = await r.text(); let j = null; try { j = txt ? JSON.parse(txt) : null; } catch (e) {}
    if (!r.ok) { const m = (j && (j.message || j.msg || j.error_description || j.error)) || ("Erreur " + r.status); const err = new Error(frMsg(m)); err.status = r.status; throw err; }
    return j;
  }
  async function refresh() {
    if (!sess) return false;
    if (Date.now() < sess.expires_at * 1000 - 60000) return true;
    try { setSess(await http("POST", "/auth/v1/token?grant_type=refresh_token", { refresh_token: sess.refresh_token })); return true; }
    catch (e) { if (e.status && e.status < 500) { sess = null; saveSess(); } return !!sess; }
  }
  async function rpc(fn, args) {
    await refresh();
    if (!sess) { signedOut(); throw new Error("Session expirée. Reconnectez-vous."); }
    try { return await http("POST", "/rest/v1/rpc/" + fn, args || {}, true); }
    catch (e) { if (e.status === 401 || /jwt/i.test(e.message)) { sess = null; saveSess(); signedOut(); throw new Error("Session expirée. Reconnectez-vous."); } throw e; }
  }
  window.paddockRpc = rpc;

  // ---------- préférences locales (favoris, sons, thème) ----------
  function prefs() { try { return JSON.parse(localStorage.getItem(PKEY) || "{}"); } catch (e) { return {}; } }
  window.save = function () { if (!S) return; try { localStorage.setItem(PKEY, JSON.stringify({ fav: S.fav, wish: S.wish, set: { sound: S.set.sound, notif: S.set.notif, light: S.set.light } })); } catch (e) {} };

  // ---------- simulation locale désactivée ----------
  PLAYERS.length = 0;
  window.ensureMarket = function () {};

  function blank() {
    const p = prefs();
    return { user: null, coins: 0, packs: 0, packTs: now(), proTs: 0, evPackTs: 0, evUntil: 0, col: {}, holo: {}, seen: {}, fav: p.fav || [], wish: p.wish || [],
      show: [null, null, null], stats: {}, claimed: [], offers: [], history: [], listings: [], sales: [], guild: null, friends: [], chats: {}, notifs: [], fc: {},
      set: Object.assign({ sound: true, notif: true, light: false, pub: true }, p.set || {}), acc: {}, ref: { count: 0, draws: 0, wins: 0 }, brandsClaimed: [],
      daily: { last: "", streak: 0 }, week: null, pendIn: 0, v3: true, v4: true };
  }
  function absorb(u) {
    if (!u || !u.u) return u && u.u;
    const a = S.acc[u.u] || (S.acc[u.u] = {});
    a.cert = !!u.cert; a.admin = !!u.admin; a.mod = !!u.mod && !u.admin; a.vip = !!u.pro; a.ac = u.ac;
    if ("ban" in u) a.ban = !!u.ban;
    if ("pro_perm" in u) { a.vip = !!u.pro_perm; a.proUntil = T(u.pro_until); }
    return u.u;
  }
  function apply(s) {
    const me = s.me, w = s.wallet;
    if (!S || !S.user || S.user.name !== me.name) { S = blank(); }
    S.user = { name: me.name, email: me.email, since: T(me.since), av: me.avatar_img ? { t: "img", d: me.avatar_img } : (me.avatar_card != null ? { t: "card", id: me.avatar_card } : null),
      banner: me.banner_img || null, nameTs: T(me.name_changed_at), invite: me.custom_invite || "", inviteCode: me.invite, guildId: me.guild_id };
    S.acc[me.name] = { cert: me.cert, mod: me.mod, admin: me.admin, vip: me.pro_permanent, proUntil: T(me.pro_until), ac: me.avatar_card };
    S.coins = w.coins; S.packs = w.packs; S.packTs = T(w.pack_ts); S.proTs = T(w.pro_pack_ts); S.evPackTs = T(w.ev_pack_ts);
    S.daily = { last: w.daily_last || "", streak: w.daily_streak };
    S.week = Object.assign({ packs: 0, wins: 0, fus: 0, deals: 0, claimed: [] }, w.week || {});
    S.stats = Object.assign({ packs: 0, trades: 0, wins: 0, battles: 0, auctions: 0, sales: 0, fus: 0 }, w.stats || {});
    S.claimed = w.ach_claimed || []; S.brandsClaimed = w.brands_claimed || [];
    S.ref = { count: w.ref_count, draws: w.ref_draws, wins: w.ref_wins };
    S.col = {}; S.holo = {};
    for (const [id, n, h] of s.inventory || []) { if (!CARS[id]) continue; S.col[id] = n; if (h) S.holo[id] = h; }
    S.notifs = (s.notifs || []).map(n => ({ t: T(n.t), txt: n.txt, read: n.read }));
    S.evUntil = T(s.event_until);
    const sc = (me.showcase || []).slice(0, 3); while (sc.length < 3) sc.push(null); S.show = sc;
    S.set.pub = me.public; S.pendIn = s.pending_in || 0; S.unreadMsgs = s.unread_msgs || 0;
  }
  async function sync() {
    if (syncing) return; syncing = true;
    try {
      const [st, sub, lv] = await Promise.all([rpc("get_state"), rpc("get_sub").catch(() => null), rpc("get_levels").catch(() => [])]);
      apply(st); S.sub = sub || {}; S.lvl = {}; for (const [id, l] of lv || []) S.lvl[id] = l; lastSync = Date.now();
    } finally { syncing = false; }
  }
  window.paddockSync = sync;

  // ---------- chargement des données par page ----------
  async function loadFor(v) {
    try {
      if (v === "market" || v === "listing") {
        const l = await rpc("get_market");
        S.listings = l.map(x => ({ id: String(x.id), card: x.card, holo: x.holo, seller: absorb(x.seller), mine: x.mine, start: x.start, end: T(x.end), t: T(x.t), bids: x.bids.map(b => ({ who: b.who, amt: b.amt })) }));
      } else if (v === "trades") {
        const l = await rpc("get_trades");
        const m = l.map(x => ({ id: String(x.id), dir: x.dir, who: absorb(x.who), give: x.give, want: x.want, status: x.status, t: T(x.t) }));
        S.offers = m.filter(x => x.status === "pending"); S.history = m.filter(x => x.status !== "pending");
      } else if (v === "friends" || v === "battle") {
        S.friends = (await rpc("get_friends")).map(absorb);
        if (v === "battle") await liveList(true);
      } else if (v === "messages") {
        const l = await rpc("get_chats"); S.chats = {};
        for (const c of l) { const n = absorb(c); S.chats[n] = { msgs: [{ me: false, txt: c.last }], unread: c.unread > 0 }; }
      } else if (v === "chat") {
        const l = await rpc("get_messages", { name: U.chat });
        S.chats[U.chat] = { msgs: l.map(m => ({ me: m.me, txt: m.txt, t: T(m.t) })), unread: false };
      } else if (v === "guild") {
        const g = await rpc("get_guild");
        S.guild = g.mine ? { name: g.mine.name, owner: g.mine.owner, members: (g.mine.members || []).map(absorb) } : null;
        U.guildRank = g.ranking || [];
      } else if (v === "ranking") {
        U.rank = (await rpc("get_ranking")).map(p => { absorb(p); return p; });
      } else if (v === "mod") {
        U.modNames = (await rpc("mod_list", { q: "" })).map(absorb);
      } else return;
      if (U.view === v || (v === "market" && U.view === "listing")) render(true);
    } catch (e) { toast(e.message); }
  }
  const _go = window.go;
  window.go = function (v) { _go(v); if (S && S.user) loadFor(v); };

  // avatars des autres joueurs (carte légendaire choisie)
  const _avInner = window.avInner;
  window.avInner = function (n) {
    if (S && S.user && n === S.user.name) return _avInner(n);
    const a = S && S.acc && S.acc[n];
    if (a && a.ac != null && CARS[a.ac]) return cardAv(a.ac);
    return esc(String(n)[0].toUpperCase());
  };

  // ---------- écran de connexion ----------
  const _signup = window.signupHTML;
  window.signupHTML = function () {
    let h = _signup();
    const inv = (() => { try { return sessionStorage.getItem("paddock-invite") || ""; } catch (e) { return ""; } })();
    h = h.replace("Adresse e-mail ou nom d'utilisateur", "Adresse e-mail")
      .replace('<div class="fine" style="margin:0">Démo : votre partie est enregistrée uniquement sur cet appareil.</div>', "")
      .replace('<div class="fine" style="margin:0">Les comptes sont enregistrés sur l\'appareil où ils ont été créés.</div>', "")
      .replace("J'accepte les conditions d'utilisation et les règles de la communauté.", 'J\'accepte les <a href="cgu.html" target="_blank">conditions d\'utilisation</a> et la <a href="confidentialite.html" target="_blank">politique de confidentialité</a>.')
      .replace('<label class="chk"><input type="checkbox" id="sc">', `<div class="field"><label for="si">Code d'invitation (facultatif)</label><input class="input" id="si" maxlength="20" value="${esc(inv)}"></div><label class="chk"><input type="checkbox" id="sc">`);
    return h;
  };
  function signedOut() { S = null; U.view = "packs"; render(); }

  async function afterLogin(msg) {
    await sync(); U.view = "packs"; render(); window.scrollTo(0, 0); if (msg) toast(msg);
  }

  window.OS = {
    sgf: async e => {
      const u = $("#su").value.trim(), m = $("#se").value.trim(), p = $("#sp").value, c = $("#sc").checked, inv = ($("#si") && $("#si").value.trim()) || "";
      let ok = true; const set = (id, t) => { const el = $("#" + id); if (el) el.textContent = t; if (t) ok = false; };
      set("eu", /^[A-Za-z0-9_.-]{3,20}$/.test(u) ? "" : "3 à 20 caractères : lettres, chiffres, _ . -");
      set("ee", /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(m) ? "" : "Entrez une adresse e-mail valide.");
      set("ep", p.length >= 8 ? "" : "Le mot de passe doit faire au moins 8 caractères.");
      set("ec", c ? "" : "Cochez la case pour accepter les conditions.");
      if (!ok) return;
      const btn = e.target.querySelector("button[type=submit]"); btn.disabled = true;
      try {
        const free = await http("POST", "/rest/v1/rpc/username_available", { q: u });
        if (!free) { set("eu", "Ce pseudo est déjà pris."); return; }
        const j = await http("POST", "/auth/v1/signup", { email: m, password: p, data: { username: u, invite: inv } });
        try { sessionStorage.removeItem("paddock-invite"); } catch (x) {}
        if (j && j.access_token) { setSess(j); await afterLogin("Bienvenue au paddock ! 10 paquets vous attendent."); }
        else modal(`<h2>Vérifiez vos e-mails</h2><p style="color:var(--muted)">Nous avons envoyé un lien de confirmation à <b>${esc(m)}</b>. Cliquez dessus, puis revenez vous connecter.</p><button class="btn green block" data-act="close">Compris</button>`, 1);
      } catch (x) { set("ec", x.message); } finally { btn.disabled = false; }
    },
    lgf: async e => {
      const m = $("#le").value.trim(), p = $("#lp").value, el = $("#el");
      if (!m || !p) { el.textContent = "Entrez votre e-mail et votre mot de passe."; return; }
      const btn = e.target.querySelector("button[type=submit]"); btn.disabled = true;
      try { setSess(await http("POST", "/auth/v1/token?grant_type=password", { email: m, password: p })); await afterLogin("Bon retour au paddock !"); }
      catch (x) { el.textContent = x.message; } finally { btn.disabled = false; }
    },
    chatf: async () => {
      const i = $("#chatin"); const v = i.value.trim(); if (!v) return; i.value = "";
      try { await rpc("send_message", { name: U.chat, body: v }); await loadFor("chat"); setTimeout(() => $("#chatin") && $("#chatin").focus(), 0); } catch (x) { toast(x.message); }
    },
    modadd: () => {}
  };

  // ---------- actions ----------
  const act = (fn) => async (el, d, e) => { try { await fn(el, d, e); } catch (x) { toast(x.message); } };
  const after = async (v) => { await sync(); if (v) await loadFor(v); render(true); };
  const packOrder = list => {
    const rk = id => CARS[id].r === "ED" ? -1 : RAR.indexOf(CARS[id].r);
    list.sort((a, b) => rk(b.id) - rk(a.id));
    return { ids: list.map(x => x.id), fresh: list.map(x => x.new), holo: list.map(x => x.holo), i: 0 };
  };
  async function openKind(kind) {
    const p = $("#packbtn"); if (p) p.classList.add("shake"); blip(kind === "pro" ? 500 : 380, .15);
    const [res] = await Promise.all([rpc("open_pack", { kind }), new Promise(r => setTimeout(r, 650))]);
    U.reveal = packOrder(res.filter(x => CARS[x.id]));
    blip(700, .12); _go("reveal"); sync().then(() => {}).catch(() => {});
  }
  async function portal() {
    const j = await http("POST", "/functions/v1/create-portal", { returnUrl: location.origin + location.pathname }, true);
    if (j && j.url) location.href = j.url; else throw new Error("Page de gestion indisponible pour le moment.");
  }
  // ---------- Boutique : abonnement Paddock Pro ----------
  const priceLabel = () => CFG.proPriceLabel ? ` · ${esc(CFG.proPriceLabel)}` : "";
  function subPanel() {
    const s = S.sub || {}, end = s.end ? new Date(s.end).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) : "";
    const active = ["active", "trialing"].includes(s.status), late = s.status === "past_due";
    if (active && s.cancel) return `<div style="color:var(--muted)">Abonnement résilié : Paddock Pro reste actif jusqu'au ${end}.</div><button class="btn ghost block" data-act="manage">Reprendre ou gérer mon abonnement</button>`;
    if (active) return `<div style="color:var(--muted)">Abonnement actif${end ? ` · prochain renouvellement le ${end}` : ""}.</div><button class="btn ghost block" data-act="manage">Gérer ou résilier mon abonnement</button>`;
    if (late) return `<div style="color:var(--red)">Le dernier paiement a échoué. Mettez à jour votre carte pour garder Paddock Pro.</div><button class="btn danger block" data-act="manage">Mettre à jour mon moyen de paiement</button>`;
    if (S.acc[S.user.name] && S.acc[S.user.name].vip) return `<div style="color:var(--muted)">Paddock Pro vous a été offert par la modération.</div>`;
    return `<button class="btn pro block" data-act="buypro">S'abonner${priceLabel()}${CFG.proPriceLabel ? " / mois" : ""}</button><div style="color:var(--dim);font-size:13px">Renouvellement automatique chaque mois. Résiliable à tout moment, sans engagement.</div>`;
  }
  const _shop = V.shop;
  V.shop = function () {
    let h = _shop();
    const btn = '<button class="btn pro block" data-act="getpro">Obtenir Paddock Pro</button>';
    const panel = CFG.paymentsEnabled ? subPanel() : '<div style="color:var(--dim);font-size:13px">L\'abonnement sera bientôt disponible.</div>';
    if (h.includes(btn)) h = h.replace(btn, panel);
    else h = h.replace("<div class=\"stack\"><h3", panel.replace(/^/, '<div class="panel stack" style="background:var(--pro-bg);border-color:var(--pro-line)">') + "</div><div class=\"stack\"><h3");
    return h;
  };
  async function checkout(product) {
    if (!CFG.paymentsEnabled) { modal(`<h2>Paiement bientôt disponible</h2><p style="color:var(--muted)">Les paiements ne sont pas encore activés sur ce site. Aucun montant n'a été débité.</p><button class="btn ghost block" data-act="close">Compris</button>`, 1); return; }
    const j = await http("POST", "/functions/v1/create-checkout", { product, returnUrl: location.origin + location.pathname }, true);
    if (j && j.url) location.href = j.url; else throw new Error("Paiement indisponible pour le moment.");
  }


  // ---------- bataille en direct ----------
  let lastLive = 0, lastInv = 0; const seenInv = new Set(), seenActive = new Set();
  const fmtSec = n => `${Math.floor(n / 60)}:${String(n % 60).padStart(2, "0")}`;
  const liveLeft = () => { const L = U.lv; return L && L.st ? Math.max(0, L.st.left - Math.floor((Date.now() - L.at) / 1000)) : 0; };
  async function livePoll(force) {
    const L = U.lv; if (!L || (L.busy && !force)) return;
    const st = await rpc("live_get", { bid: L.id });
    if (U.lv !== L) return;
    const was = L.st && L.st.status;
    if (st.foe) L.foe = absorb(st.foe);
    const key = JSON.stringify(Object.assign({}, st, { left: 0 }));
    L.at = Date.now();
    if (key !== L.key) { L.key = key; L.st = st; if (st.status === "play" && was !== "play") blip(660); if (st.status === "done" && was !== "done") { await sync(); blip(st.result === "win" ? 880 : 300); } if (U.view === "live") render(true); }
    else L.st.left = st.left;
  }
  async function liveList(quiet) {
    const r = await rpc("live_list");
    S.liveInv = (r.invites || []).map(x => ({ id: x.id, from: absorb(x.from) }));
    if (quiet) return r;
    const open = document.querySelector(".overlay");
    const fresh = S.liveInv.find(x => !seenInv.has(x.id));
    if (fresh && !open && U.view !== "live") {
      S.liveInv.forEach(x => seenInv.add(x.id));
      modal(`<h2>Défi en direct</h2><p style="color:var(--muted)">${nm(fresh.from)} vous défie en bataille en direct.</p><div class="row"><button class="btn ghost grow" data-act="lvno" data-id="${fresh.id}">Refuser</button><button class="btn green grow" data-act="lvyes" data-id="${fresh.id}">Jouer</button></div>`, 1);
    } else if (r.active && !seenActive.has(r.active) && !open && U.view !== "live" && !(U.lv && U.lv.id === r.active)) {
      seenActive.add(r.active);
      modal(`<h2>Bataille en direct</h2><p style="color:var(--muted)">Une bataille en direct vous attend.</p><div class="row"><button class="btn ghost grow" data-act="close">Plus tard</button><button class="btn green grow" data-act="lvresume" data-id="${r.active}">Reprendre</button></div>`, 1);
    }
    if (U.view === "battle") render(true);
    return r;
  }
  function openLive(id) { U.lv = { id, st: null, pick: [], at: Date.now() }; seenActive.add(id); closeModal(); window.go("live"); livePoll(true).catch(e => toast(e.message)); }
  const resTxt = (e, foe) => bResTxt(e.res, e.a, e.z, e.stat, e.by_me ? "" : foe);
  const rlog = (log, foe) => log.length ? `<div class="rlog">${log.map((e, i) => `<div><span>Manche ${i + 1} · ${e.by_me ? "vous" : esc(foe)} · ${e.stat === "hp" ? "attaque" : "défense"} · ${fmt(e.a)} contre ${fmt(e.z)}</span><b class="${e.res > 0 ? "w" : e.res < 0 ? "l" : "d"}">${e.res > 0 ? "Gagnée" : e.res < 0 ? "Perdue" : "Égalité"}</b></div>`).join("")}</div>` : "";
  V.live = () => {
    const L = U.lv;
    if (!L) return `<div class="pagehead"><h1>Bataille en direct</h1></div><div class="panel empty"><b>Aucune partie en cours</b><button class="btn green" data-act="go" data-v="battle">Retour aux batailles</button></div>`;
    const st = L.st, foe = L.foe || "Adversaire";
    if (!st) return `<div class="pagehead"><h1>Bataille en direct</h1><p>Connexion à la partie…</p></div><div class="panel"><div class="spin"></div></div>`;
    const left = liveLeft();
    const score = `<div class="score" style="margin-bottom:14px"><span>Vous <b>${st.score[0]}</b></span><span>${esc(foe)} <b>${st.score[1]}</b></span></div>`;
    if (st.status === "cancel") return `<div class="pagehead"><h1>Partie annulée</h1><p>Le défi a expiré, a été refusé ou annulé.</p></div><div class="row"><button class="btn ghost grow" data-act="lvquit">Retour</button><button class="btn green grow" data-act="lvfind">Chercher un adversaire</button></div>`;
    if (st.status === "done") {
      const t = st.result === "win" ? "Victoire !" : st.result === "draw" ? "Égalité" : "Défaite";
      return `<div class="pagehead"><h1>${t}</h1><p>${st.reward ? `Vous gagnez ${st.reward} pistons.` : st.log.length < 3 ? "La partie s'est terminée avant la fin (abandon ou temps écoulé)." : "Améliorez vos voitures et retentez votre chance."}</p></div>
        <div class="score panel"><span>Vous <b>${st.score[0]}</b></span><span>${esc(foe)} <b>${st.score[1]}</b></span></div>${rlog(st.log, foe)}
        <div class="row" style="margin-top:16px"><button class="btn ghost grow" data-act="lvquit">Terminer</button>${st.mode === "random" ? '<button class="btn green grow" data-act="lvfind">Rejouer</button>' : `<button class="btn green grow" data-act="lvinvite" data-f="${esc(foe)}">Revanche</button>`}</div>`;
    }
    if (st.status === "invite") return `<div class="pagehead"><h1>${st.mode === "random" ? "Recherche d'un adversaire" : "Défi envoyé"}</h1><p>${st.mode === "random" ? "La partie démarre dès qu'un autre joueur cherche aussi un adversaire." : `En attente de la réponse de ${esc(foe)}.`}</p></div>
      <div class="panel livebox" style="text-align:center"><div class="spin"></div><div>Expire dans <span class="timer" id="lvtimer">${fmtSec(left)}</span></div><button class="btn ghost block" data-act="lvcancel">Annuler</button></div>`;
    if (st.status === "pick") {
      if (st.picks) return `<div class="pagehead"><h1>Contre ${esc(foe)}</h1><p>Vos voitures sont prêtes. En attente de celles de ${esc(foe)}…</p></div><div class="panel livebox" style="text-align:center"><div class="spin"></div><div>Temps restant <span class="timer" id="lvtimer">${fmtSec(left)}</span></div><button class="btn ghost block" data-act="lvcancel">Abandonner</button></div>`;
      const mine = sortIds(Object.keys(S.col).map(Number), "atk");
      return `<div class="pagehead"><h1>Contre ${esc(foe)}</h1><p>Choisissez 3 voitures (${L.pick.length}/3) · <span class="timer" id="lvtimer">${fmtSec(left)}</span>${st.foe_ready ? ` · ${esc(foe)} est prêt` : ""}</p></div>
        <div class="row" style="margin-bottom:14px"><button class="btn ghost grow" data-act="lvauto">Choix automatique</button><button class="btn green grow" data-act="lvgo" ${L.pick.length === 3 ? "" : "disabled"}>Valider</button></div>
        <div class="pickgrid">${mine.slice(0, 60).map(id => cardHTML(id, { act: "lvpick", own: true, cls: L.pick.includes(id) ? "sel" : "" })).join("")}</div>
        <button class="btn ghost block" style="margin-top:16px" data-act="lvcancel">Annuler la partie</button>`;
    }
    const k = Math.min(st.round, 2), my = st.picks[k], last = st.log[st.log.length - 1];
    return `<div class="pagehead"><h1>Manche ${k + 1} / 3</h1><p>${last ? esc(resTxt(last, foe)) : "Chacun a choisi ses voitures. C'est parti !"}</p></div>${score}
      <div class="arena">${cardHTML(my, { lv: st.lv[k] })}<span class="vs">VS</span><div class="facedown">?</div></div>
      ${st.my_turn ? `<div class="turnnote">À vous de choisir · <span class="timer" id="lvtimer">${left}s</span></div><div class="row" style="margin-top:12px"><button class="btn ghost grow" data-act="lvmove" data-s="hp"><span style="color:#e58a6e;display:inline-flex">${I.atk}</span>Attaque</button><button class="btn ghost grow" data-act="lvmove" data-s="v"><span style="color:#8fb4e0;display:inline-flex">${I.def}</span>Défense</button></div>`
        : `<div class="turnnote">${esc(foe)} choisit la stat · <span class="timer" id="lvtimer">${left}s</span></div><div class="spin" style="margin-top:12px"></div>`}
      ${rlog(st.log, foe)}<button class="btn ghost block" style="margin-top:16px" data-act="lvcancel">Abandonner</button>`;
  };
  window.OA = {
    // améliorations
    upgrade: act(async (el, d) => {
      const id = +d.id; const r = await rpc("upgrade_card", { cid: id });
      S.lvl[id] = r.lvl; S.coins = r.coins; blip(880); toast(`${CARS[id].n} passe au niveau ${r.lvl} !`); cardModal(id); render(true);
    }),
    // bataille en direct
    btab: act(async (el, d) => { U.btab = d.t; render(); if (d.t === "live") await liveList(true).then(() => render(true)); }),
    lvfind: act(async () => { const r = await rpc("live_find"); openLive(r.id); }),
    lvinvite: act(async (el, d) => { const r = await rpc("live_invite", { name: d.f }); openLive(r.id); }),
    lvyes: act(async (el, d) => { await rpc("live_respond", { bid: +d.id, accept: true }); openLive(+d.id); }),
    lvno: act(async (el, d) => { await rpc("live_respond", { bid: +d.id, accept: false }); closeModal(); S.liveInv = (S.liveInv || []).filter(x => x.id !== +d.id); render(true); }),
    lvresume: act(async (el, d) => { openLive(+d.id); }),
    lvcancel: act(async () => { const L = U.lv; if (!L) return; await rpc("live_cancel", { bid: L.id }); await livePoll(true); }),
    lvpick: (el) => { const L = U.lv; const id = +el.dataset.card; if (L.pick.includes(id)) L.pick = L.pick.filter(x => x !== id); else if (L.pick.length < 3) L.pick.push(id); render(true); },
    lvauto: () => { const L = U.lv; L.pick = Object.keys(S.col).map(Number).sort((a, b) => pw(b) * (1 + LVB * (lvOf(b) - 1)) - pw(a) * (1 + LVB * (lvOf(a) - 1))).slice(0, 3); render(true); },
    lvgo: act(async () => { const L = U.lv; L.busy = true; try { await rpc("live_pick", { bid: L.id, picks: L.pick }); await livePoll(true); } finally { L.busy = false; } }),
    lvmove: act(async (el, d) => { const L = U.lv; if (L.busy) return; L.busy = true; try { await rpc("live_move", { bid: L.id, stat: d.s }); await livePoll(true); } finally { L.busy = false; } }),
    lvquit: () => { U.lv = null; U.btab = "live"; window.go("battle"); },
    open: act(async () => { if (!S.packs) return toast("Plus de paquet disponible pour l'instant."); await openKind("normal"); }),
    openpro: act(async () => { await openKind("pro"); }),
    openev: act(async () => { await openKind("event"); }),
    daily: act(async () => { const r = await rpc("claim_daily"); blip(780); toast(`Jour ${r.day} : ${dailyTxt({ c: r.coins, p: r.packs })}`); await after(); }),
    wkclaim: act(async (el, d) => { const n = await rpc("claim_week", { i: +d.i }); toast(`+${n} pistons`); await after(); }),
    claim: act(async (el, d) => { const n = await rpc("claim_ach", { i: +d.i }); toast(`+${n} pistons`); await after(); }),
    brandclaim: act(async (el, d) => { const n = await rpc("claim_brand", { b: d.b }); toast(`Marque ${d.b} complétée : +${n} pistons`); await after(); }),
    fusego: act(async (el, d) => {
      const r = await rpc("fuse", { r: d.r }); blip(900, .25); await sync();
      modal(`<h2><span>Fusion réussie</span><button class="x" data-act="close" aria-label="Fermer">${I.x}</button></h2>${cardHTML(r.id, { big: true, isnew: r.new })}<button class="btn green block" style="margin-top:14px" data-act="fuse">Continuer</button>`); render(true);
    }),
    refdraw: act(async () => {
      modal(`<div style="text-align:center;padding:20px 0"><p style="color:var(--muted)">Tirage en cours…</p></div>`, 1);
      const [r] = await Promise.all([rpc("ref_draw"), new Promise(x => setTimeout(x, 1200))]);
      const msg = r.win && r.until ? `Gagné ! Vous profitez de Paddock Pro jusqu'au ${new Date(r.until).toLocaleDateString("fr-FR", { day: "numeric", month: "long" })}.`
        : r.converted ? "Gagné ! Vous êtes déjà membre Paddock Pro : vous recevez 2 paquets bonus." : "Pas cette fois. Vous gagnez 2 paquets bonus. Invitez 3 nouveaux amis pour retenter votre chance.";
      blip(r.win ? 880 : 330, .25);
      modal(`<div style="text-align:center"><h2 style="justify-content:center;font-size:26px">${r.win ? "Gagné !" : "Perdu…"}</h2><p style="color:var(--muted)">${esc(msg)}</p><button class="btn ${r.win ? "pro" : "green"} block" data-act="close">${r.win ? "Génial" : "D'accord"}</button></div>`, 1);
      await after();
    }),
    notifs: act(async () => {
      const h = S.notifs.length ? `<div class="stack">${S.notifs.map(n => `<div class="lrow" style="${n.read ? "" : "border:1px solid var(--green-d)"}"><div class="grow"><div>${esc(n.txt)}</div><div class="sub">${new Date(n.t).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}</div></div></div>`).join("")}</div>` : '<div class="empty">Aucune notification.</div>';
      modal(`<h2><span>Notifications</span><button class="x" data-act="close" aria-label="Fermer">${I.x}</button></h2>${h}`);
      if (S.notifs.some(n => !n.read)) { await rpc("mark_notifs_read"); S.notifs.forEach(n => n.read = true); render(true); }
    }),
    // marché
    bid: act(async () => {
      const v = parseInt($("#bidin").value) || 0;
      await rpc("place_bid", { lid: +U.lid, amount: v }); blip(660); toast(`Mise de ${fmt(v)} pistons placée.`); U.bid = 0; await after("market");
    }),
    sellgo: act(async (el, d) => {
      await rpc("create_listing", { card: +d.id, price: Math.max(5, parseInt($("#sprice").value) || 0), minutes: +$("#sdur").value });
      closeModal(); U.mk.tab = "mine"; toast("Carte mise en vente."); await sync(); window.go("market");
    }),
    // échanges
    newtrade: act(async (el, d) => {
      if (!S.friends.length) S.friends = (await rpc("get_friends")).map(absorb);
      if (!S.friends.length) return toast("Ajoutez d'abord un ami.");
      const who = d.f || S.friends[0];
      S.fc[who] = (await rpc("get_inventory_of", { name: who })).map(x => x[0]);
      tradeModal(who);
    }),
    trsend: act(async () => {
      await rpc("propose_trade", { name: TR.who, give: TR.give, want: TR.want });
      closeModal(); U.tr = "out"; toast(`Offre envoyée à ${TR.who}.`); window.go("trades");
    }),
    tryes: act(async (el, d) => { await rpc("respond_trade", { tid: +d.id, accept: true }); toast("Échange accepté."); await after("trades"); }),
    trno: act(async (el, d) => { await rpc("respond_trade", { tid: +d.id, accept: false }); await after("trades"); }),
    // amis
    findp: act(async () => {
      modal(`<h2><span>Rechercher un joueur</span><button class="x" data-act="close" aria-label="Fermer">${I.x}</button></h2><input class="input" id="pq" placeholder="Nom d'utilisateur…" autocomplete="off" style="border-color:var(--green-d)"><div id="pres" style="margin-top:14px"><div class="empty" style="padding:20px">Entrez au moins 2 caractères…</div></div>`);
      const q = $("#pq"); q.focus(); let tm = 0;
      q.addEventListener("input", () => {
        clearTimeout(tm); const v = q.value.trim(); const r = $("#pres");
        if (v.length < 2) { r.innerHTML = '<div class="empty" style="padding:20px">Entrez au moins 2 caractères…</div>'; return; }
        tm = setTimeout(async () => {
          try {
            const m = await rpc("search_players", { q: v }); m.forEach(absorb);
            if (!$("#pres")) return;
            $("#pres").innerHTML = m.length ? `<div class="stack">${m.map(p => `<div class="lrow"><div class="av" style="background:${avColor(p.u)}">${avInner(p.u)}</div><div class="name">${nm(p.u)}</div>${p.friend ? '<span class="pill">Ami</span>' : `<button class="btn green" style="padding:8px 14px" data-act="addf" data-f="${esc(p.u)}">Ajouter</button>`}</div>`).join("")}</div>` : '<div class="empty" style="padding:20px">Aucun joueur trouvé.</div>';
          } catch (x) { toast(x.message); }
        }, 300);
      });
    }),
    addf: act(async (el, d) => { await rpc("add_friend", { name: d.f }); toast(`${d.f} ajouté à vos amis.`); el.outerHTML = '<span class="pill">Ami</span>'; await loadFor("friends"); }),
    chat: act(async (el, d) => { U.chat = d.f; S.chats[d.f] = S.chats[d.f] || { msgs: [], unread: false }; closeModal(); window.go("chat"); }),
    // batailles
    bgo: act(async () => {
      const B = U.battle; const r = await rpc("battle_start", { name: B.foe, picks: B.pick });
      B.id = r.id; B.foeCards = [null, null, null]; B.myLv = r.my_lv || [1, 1, 1]; B.foeLv = [1, 1, 1]; B.phase = "play"; B.round = 0; B.score = [0, 0]; B.res = ""; render();
    }),
    bstat: act(async (el, d) => {
      const B = U.battle; if (B.res) return;
      const r = await rpc("battle_play", { bid: B.id, stat: d.s === "ai" ? "hp" : d.s });
      B.foeCards[B.round] = r.foe; B.foeLv[B.round] = r.foe_lv || 1; B.score = r.score; B.reward = r.reward; B.done = r.done;
      B.res = bResTxt(r.res, r.a, r.z, r.stat, B.round === 1 ? B.foe : "");
      blip(r.res > 0 ? 780 : r.res < 0 ? 240 : 500); render();
    }),
    bnext: act(async () => { const B = U.battle; B.res = ""; if (B.round < 2) B.round++; else { B.phase = "end"; await sync(); } render(); }),
    // écuries
    gcreate: act(async () => { const n = $("#gname").value.trim(); await rpc("create_guild", { name: n }); toast("Écurie créée."); await after("guild"); }),
    ginvite: act(async () => {
      if (!S.friends.length) S.friends = (await rpc("get_friends")).map(absorb);
      const c = S.friends.filter(f => !(S.guild && S.guild.members.includes(f)));
      if (!c.length) return toast("Tous vos amis sont déjà dans l'écurie.");
      modal(`<h2><span>Inviter dans l'écurie</span><button class="x" data-act="close" aria-label="Fermer">${I.x}</button></h2><div class="stack">${c.map(f => `<div class="lrow"><div class="av" style="background:${avColor(f)}">${avInner(f)}</div><div class="name">${nm(f)}</div><button class="btn green" style="padding:8px 14px" data-act="ginv1" data-f="${esc(f)}">Inviter</button></div>`).join("")}</div>`);
    }),
    ginv1: act(async (el, d) => { await rpc("guild_invite", { name: d.f }); closeModal(); toast(`${d.f} a rejoint l'écurie.`); await after("guild"); }),
    gleave: act(async () => { await rpc("leave_guild"); await after("guild"); }),
    // modération
    modt: act(async (el, d) => {
      const a = A(d.n); const flag = d.k === "vip" ? "pro" : d.k;
      const cur = flag === "pro" ? !!a.vip : flag === "mod" ? !!(a.mod || a.admin) : !!a[flag];
      await rpc("mod_set", { name: d.n, flag, val: !cur }); toast("Compte mis à jour."); await after("mod");
    }),
    evtoggle: act(async () => { await rpc("set_event", { days: evOn() ? 0 : 7 }); toast(evOn() ? "Événement arrêté." : "Événement lancé pour 7 jours."); await after("mod"); }),
    evextend: act(async () => { await rpc("set_event", { days: 7 }); toast("Événement prolongé de 7 jours."); await after("mod"); }),
    // profil et paramètres
    saveacc: act(async () => {
      const n = $("#suser").value.trim(), m = $("#semail").value.trim();
      if (n !== S.user.name) await rpc("set_profile", { field: "username", val: n });
      if (m !== S.user.email) { await http("PUT", "/auth/v1/user", { email: m }, true); toast("Un lien de confirmation a été envoyé à votre nouvelle adresse."); }
      else toast("Sauvegardé.");
      await after();
    }),
    saveinv: act(async () => { const v = $("#sinv").value.trim(); await rpc("set_profile", { field: "invite", val: v }); toast(v ? "Lien d'invitation personnalisé enregistré." : "Code par défaut rétabli."); await after(); }),
    setavcard: act(async (el, d) => { await rpc("set_profile", { field: "avatar_card", val: String(d.id) }); closeModal(); toast("Photo de profil mise à jour."); await after(); }),
    rmav: act(async () => { await rpc("set_profile", { field: "avatar_card", val: "" }); closeModal(); await after(); }),
    rmbanner: act(async () => { await rpc("set_profile", { field: "banner_img", val: "" }); closeModal(); await after(); }),
    set: act(async (el, d) => {
      if (d.k === "pub") { await rpc("set_profile", { field: "public", val: String(!S.set.pub) }); await after(); return; }
      S.set[d.k] = !S.set[d.k]; save(); render();
    }),
    showpick: act(async (el) => {
      const sh = S.show.slice(); sh[U.showK] = +el.dataset.card;
      await rpc("set_profile", { field: "showcase", val: "{" + sh.map(x => x == null ? "NULL" : x).join(",") + "}" }); closeModal(); await after();
    }),
    unshow: act(async (el, d) => {
      const sh = S.show.slice(); sh[+d.k] = null;
      await rpc("set_profile", { field: "showcase", val: "{" + sh.map(x => x == null ? "NULL" : x).join(",") + "}" }); await after();
    }),
    buy: act(async (el, d) => { await checkout(+d.n === 5000 ? "pistons_5000" : "pistons_2500"); }),
    buypro: act(async () => { await checkout("pro_month"); }),
    manage: act(async () => { await portal(); }),
    logout2: act(async () => { try { await http("POST", "/auth/v1/logout", {}, true); } catch (x) {} sess = null; saveSess(); closeModal(); signedOut(); }),
    wipe2: act(async () => { await rpc("delete_account"); sess = null; saveSess(); closeModal(); signedOut(); toast("Compte supprimé."); }),
    forgot: act(async () => {
      const m = ($("#fe") && $("#fe").value.trim()) || ($("#le") && $("#le").value.trim()) || "";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(m)) { const el = $("#fer") || $("#el"); if (el) el.textContent = "Entrez une adresse e-mail valide."; return; }
      await http("POST", "/auth/v1/recover", { email: m });
      modal(`<h2>E-mail envoyé</h2><p style="color:var(--muted)">Si un compte existe avec <b>${esc(m)}</b>, vous allez recevoir un lien pour choisir un nouveau mot de passe.</p><button class="btn green block" data-act="close">Compris</button>`, 1);
    }),
    newpw: act(async () => {
      const p = $("#npw").value; if (p.length < 8) return toast("Le mot de passe doit faire au moins 8 caractères.");
      await http("PUT", "/auth/v1/user", { password: p }, true); closeModal(); toast("Mot de passe modifié.");
    }),
    // actions purement locales désactivées en ligne
    pro: () => {}, addcoins: () => {}, wipe: (el, d) => modal(`<h2>Supprimer le compte ?</h2><p style="color:var(--muted)">Votre compte, vos cartes et vos pistons seront définitivement supprimés.</p><div class="row"><button class="btn ghost grow" data-act="close">Annuler</button><button class="btn danger grow" data-act="wipe2">Supprimer</button></div>`, 1)
  };

  // le pack Paddock Pro peut s'acheter depuis la fenêtre d'offre
  const _getpro = null;
  document.addEventListener("click", e => {
    const el = e.target.closest('[data-act="getpro"]'); if (!el || !CFG.paymentsEnabled) return;
    setTimeout(() => { const m = $(".modal"); if (m && !m.querySelector('[data-act="buypro"]')) { const b = document.createElement("button"); b.className = "btn pro block"; b.dataset.act = "buypro"; b.textContent = "S'abonner à Paddock Pro" + (CFG.proPriceLabel ? " · " + CFG.proPriceLabel + " / mois" : ""); b.style.marginTop = "10px"; m.appendChild(b); } }, 0);
  }, true);

  // changement d'ami dans la fenêtre d'échange
  window.onTradeWho = async who => {
    try { S.fc[who] = (await rpc("get_inventory_of", { name: who })).map(x => x[0]); TR.who = who; TR.want = null; drawTrade(); } catch (x) { toast(x.message); }
  };

  // import de photo et de bannière
  window.OC = e => {
    if ((e.target.id === "avfile" || e.target.id === "bnfile") && e.target.files[0]) {
      const isAv = e.target.id === "avfile";
      shrinkImage(e.target.files[0], isAv ? 256 : 1200, isAv ? 256 : 400, async data => {
        try { await rpc("set_profile", { field: isAv ? "avatar_img" : "banner_img", val: data }); closeModal(); toast(isAv ? "Photo de profil mise à jour." : "Bannière mise à jour."); await after(); }
        catch (x) { toast(x.message); }
      });
      return true;
    }
    return false;
  };

  // ---------- horloge ----------
  window.onlineTick = function () {
    if (!S || !S.user) return;
    updateTimers();
    const t = Date.now(), typing = document.activeElement && /INPUT|TEXTAREA/.test(document.activeElement.tagName);
    if (!typing && !syncing && t - lastSync > 30000) sync().then(() => render(true)).catch(() => {});
    if (!typing && t - lastPoll > (U.view === "chat" ? 5000 : 12000) && ["chat", "market", "listing", "trades"].includes(U.view)) { lastPoll = t; loadFor(U.view === "listing" ? "market" : U.view); }
    if (U.view === "live" && U.lv) {
      const tm = document.getElementById("lvtimer"); if (tm) { const l = liveLeft(); tm.textContent = U.lv.st && U.lv.st.status === "play" ? l + "s" : fmtSec(l); }
      const st = U.lv.st && U.lv.st.status;
      if (st !== "done" && st !== "cancel" && t - lastLive > 1500) { lastLive = t; livePoll().catch(() => {}); }
    } else if (t - lastInv > 10000) { lastInv = t; liveList().catch(() => {}); }
  };

  // ---------- démarrage ----------
  async function boot() {
    const m = location.hash.match(/^#invite-([A-Za-z0-9_.-]{3,20})$/);
    if (m) { try { sessionStorage.setItem("paddock-invite", m[1]); } catch (e) {} }
    // retour du lien « mot de passe oublié » ou de confirmation d'e-mail
    const h = new URLSearchParams(location.hash.replace(/^#/, ""));
    if (h.get("access_token")) {
      setSess({ access_token: h.get("access_token"), refresh_token: h.get("refresh_token"), expires_in: +h.get("expires_in") || 3600 });
      history.replaceState(null, "", location.pathname);
      if (h.get("type") === "recovery") setTimeout(() => modal(`<h2>Nouveau mot de passe</h2><div class="stack"><input class="input" id="npw" type="password" placeholder="8 caractères minimum" autocomplete="new-password"><button class="btn green block" data-act="newpw">Enregistrer</button></div>`, 1), 400);
    }
    if (!SB || !KEY) {
      $("#app").innerHTML = `<div class="panel empty" style="margin-top:40px"><b>Configuration manquante</b>Renseignez l'adresse et la clé publique Supabase dans le fichier config.js.</div>`; return;
    }
    S = null;
    if (sess) { try { await sync(); } catch (e) { if (!sess) S = null; } }
    render();
    if (location.hash === "#paiement-ok") { history.replaceState(null, "", location.pathname); setTimeout(() => toast("Paiement reçu, merci ! Votre achat arrive dans quelques secondes."), 300); setTimeout(() => sync().then(() => render(true)).catch(() => {}), 4000); }
    else if (location.hash === "#paiement-annule") { history.replaceState(null, "", location.pathname); setTimeout(() => toast("Paiement annulé. Aucun montant n'a été débité."), 300); }
    setInterval(() => { if (S && S.user) tick(); }, 1000);
  }
  boot();
  if ("serviceWorker" in navigator && /^https:/.test(location.protocol)) navigator.serviceWorker.register("sw.js").catch(() => {});
})();
