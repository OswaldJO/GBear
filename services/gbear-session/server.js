#!/usr/bin/env node
/**
 * GBear session coordination server.
 *
 * - Google ID token auth (or GBEAR_DEV_AUTH=1 for local testing)
 * - Owner devices auto-join without invite
 * - Short-lived invite codes for friends (any open seat 1–8)
 * - WebRTC-style SDP/ICE signaling mailbox
 * - Short-lived TURN credentials (coturn REST or static)
 * - TCP byte relay (DERP-like) when direct ICE fails
 */
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { WebSocketServer } = require('ws');
const { OAuth2Client } = require('google-auth-library');
const { v4: uuidv4 } = require('uuid');

const PORT = Number(process.env.PORT || 8787);
const GOOGLE_CLIENT_ID = process.env.GBEAR_GOOGLE_CLIENT_ID || '';
const DEV_AUTH = process.env.GBEAR_DEV_AUTH === '1';
const TURN_HOST = process.env.GBEAR_TURN_HOST || '';
const TURN_SECRET = process.env.GBEAR_TURN_SECRET || '';
const TURN_TTL_SEC = Number(process.env.GBEAR_TURN_TTL || 3600);
const MAX_SEATS = 8;

function firstFreeSeat(taken, preferred) {
  const pref = Number(preferred);
  if (pref >= 1 && pref <= MAX_SEATS && !taken.has(pref)) return pref;
  for (let i = 1; i <= MAX_SEATS; i++) {
    if (!taken.has(i)) return i;
  }
  return null;
}

/** @type {Map<string, { email: string, devices: Map<string, object> }>} */
const accounts = new Map();
/** @type {Map<string, object>} */
const sessions = new Map();
/** @type {Map<string, object>} */
const invites = new Map();
/** @type {Map<string, import('ws').WebSocket>} */
const socketsByDevice = new Map();
/** @type {Map<string, { a?: import('ws').WebSocket, b?: import('ws').WebSocket }>} */
const relays = new Map();

const app = express();
app.use(express.json({ limit: '1mb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'gbear-session', sessions: sessions.size });
});

async function verifyGoogleToken(idToken) {
  if (DEV_AUTH && idToken?.startsWith('dev:')) {
    const email = idToken.slice(4).toLowerCase();
    return { email, sub: `dev-${email}` };
  }
  if (!googleClient || !GOOGLE_CLIENT_ID) {
    throw new Error('Google auth not configured (set GBEAR_GOOGLE_CLIENT_ID or GBEAR_DEV_AUTH=1)');
  }
  const ticket = await googleClient.verifyIdToken({
    idToken,
    audience: GOOGLE_CLIENT_ID,
  });
  const payload = ticket.getPayload();
  if (!payload?.email) throw new Error('Token missing email');
  return { email: payload.email.toLowerCase(), sub: payload.sub };
}

function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : req.body?.idToken;
  if (!token) {
    res.status(401).json({ ok: false, error: 'missing bearer token' });
    return;
  }
  verifyGoogleToken(token)
    .then((user) => {
      req.user = user;
      if (!accounts.has(user.email)) {
        accounts.set(user.email, { email: user.email, devices: new Map() });
      }
      next();
    })
    .catch((err) => {
      res.status(401).json({ ok: false, error: err.message });
    });
}

app.post('/v1/auth/register-device', authMiddleware, (req, res) => {
  const { deviceId, deviceName, role } = req.body || {};
  if (!deviceId) {
    res.status(400).json({ ok: false, error: 'deviceId required' });
    return;
  }
  const account = accounts.get(req.user.email);
  account.devices.set(deviceId, {
    deviceId,
    deviceName: deviceName || 'Device',
    role: role === 'host' ? 'host' : 'companion',
    updatedAt: Date.now(),
  });
  res.json({
    ok: true,
    email: req.user.email,
    devices: [...account.devices.values()],
  });
});

app.get('/v1/account/devices', authMiddleware, (req, res) => {
  const account = accounts.get(req.user.email);
  res.json({ ok: true, email: req.user.email, devices: [...account.devices.values()] });
});

app.post('/v1/session/create', authMiddleware, (req, res) => {
  const { hostDeviceId, hostName } = req.body || {};
  if (!hostDeviceId) {
    res.status(400).json({ ok: false, error: 'hostDeviceId required' });
    return;
  }
  const sessionId = uuidv4();
  const session = {
    sessionId,
    ownerEmail: req.user.email,
    hostDeviceId,
    hostName: hostName || 'Mac',
    createdAt: Date.now(),
    members: [
      {
        deviceId: hostDeviceId,
        email: req.user.email,
        name: hostName || 'Mac',
        seat: 0,
        role: 'host',
      },
    ],
    signals: [],
  };
  sessions.set(sessionId, session);
  res.json({ ok: true, session: publicSession(session) });
});

app.post('/v1/session/join', authMiddleware, (req, res) => {
  const { sessionId, deviceId, deviceName, preferredSeat, inviteCode } = req.body || {};
  const session = sessions.get(sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'session not found' });
    return;
  }

  const accountOwns = session.ownerEmail === req.user.email;
  let inviteOk = false;
  if (!accountOwns) {
    if (!inviteCode) {
      res.status(403).json({ ok: false, error: 'invite required' });
      return;
    }
    const invite = invites.get(String(inviteCode).toUpperCase());
    if (!invite || invite.sessionId !== sessionId || invite.expiresAt < Date.now()) {
      res.status(403).json({ ok: false, error: 'invalid or expired invite' });
      return;
    }
    inviteOk = true;
  }

  const existing = session.members.find((m) => m.deviceId === deviceId);
  if (existing) {
    res.json({ ok: true, session: publicSession(session), seat: existing.seat });
    return;
  }

  const companions = session.members.filter((m) => m.role === 'companion');
  if (companions.length >= MAX_SEATS) {
    res.status(409).json({ ok: false, error: 'session full' });
    return;
  }

  const taken = new Set(companions.map((m) => m.seat));
  const seat = firstFreeSeat(taken, preferredSeat);
  if (seat == null) {
    res.status(409).json({ ok: false, error: 'session full' });
    return;
  }

  session.members.push({
    deviceId,
    email: req.user.email,
    name: deviceName || 'Companion',
    seat,
    role: 'companion',
    viaInvite: inviteOk,
  });
  broadcast(sessionId, { type: 'session_updated', session: publicSession(session) });
  res.json({ ok: true, session: publicSession(session), seat });
});

app.post('/v1/session/invite', authMiddleware, (req, res) => {
  const { sessionId } = req.body || {};
  const session = sessions.get(sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'session not found' });
    return;
  }
  if (session.ownerEmail !== req.user.email) {
    res.status(403).json({ ok: false, error: 'only owner can invite' });
    return;
  }
  const code = crypto.randomBytes(3).toString('hex').toUpperCase();
  invites.set(code, { sessionId, expiresAt: Date.now() + INVITE_TTL_MS, ownerEmail: req.user.email });
  res.json({
    ok: true,
    inviteCode: code,
    expiresAt: new Date(Date.now() + INVITE_TTL_MS).toISOString(),
    joinHint: `Redeem invite ${code} for session ${sessionId}`,
  });
});

app.post('/v1/session/redeem-invite', authMiddleware, (req, res) => {
  const { inviteCode, deviceId, deviceName } = req.body || {};
  const invite = invites.get(String(inviteCode || '').toUpperCase());
  if (!invite || invite.expiresAt < Date.now()) {
    res.status(404).json({ ok: false, error: 'invalid or expired invite' });
    return;
  }
  req.body.sessionId = invite.sessionId;
  // Reuse join
  const session = sessions.get(invite.sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'session not found' });
    return;
  }
  const companions = session.members.filter((m) => m.role === 'companion');
  if (companions.length >= MAX_SEATS && !companions.some((m) => m.deviceId === deviceId)) {
    res.status(409).json({ ok: false, error: 'session full' });
    return;
  }
  let member = session.members.find((m) => m.deviceId === deviceId);
  if (!member) {
    const taken = new Set(companions.map((m) => m.seat));
    const seat = firstFreeSeat(taken);
    if (seat == null) {
      res.status(409).json({ ok: false, error: 'session full' });
      return;
    }
    member = {
      deviceId,
      email: req.user.email,
      name: deviceName || 'Friend',
      seat,
      role: 'companion',
      viaInvite: true,
    };
    session.members.push(member);
  }
  broadcast(invite.sessionId, { type: 'session_updated', session: publicSession(session) });
  res.json({ ok: true, session: publicSession(session), seat: member.seat });
});

app.post('/v1/session/end', authMiddleware, (req, res) => {
  const { sessionId } = req.body || {};
  const session = sessions.get(sessionId);
  if (!session) {
    res.json({ ok: true });
    return;
  }
  if (session.ownerEmail !== req.user.email) {
    res.status(403).json({ ok: false, error: 'only owner can end' });
    return;
  }
  sessions.delete(sessionId);
  broadcast(sessionId, { type: 'session_ended' });
  res.json({ ok: true });
});

app.get('/v1/session/:sessionId', authMiddleware, (req, res) => {
  const session = sessions.get(req.params.sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'not found' });
    return;
  }
  res.json({ ok: true, session: publicSession(session) });
});

app.post('/v1/signal', authMiddleware, (req, res) => {
  const { sessionId, fromDeviceId, toDeviceId, payload } = req.body || {};
  const session = sessions.get(sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'session not found' });
    return;
  }
  const message = {
    id: uuidv4(),
    fromDeviceId,
    toDeviceId,
    payload,
    at: Date.now(),
  };
  session.signals.push(message);
  if (session.signals.length > 200) session.signals.shift();
  const target = socketsByDevice.get(toDeviceId);
  if (target && target.readyState === 1) {
    target.send(JSON.stringify({ type: 'signal', sessionId, message }));
  }
  res.json({ ok: true, messageId: message.id });
});

app.get('/v1/signal/poll', authMiddleware, (req, res) => {
  const sessionId = req.query.sessionId;
  const deviceId = req.query.deviceId;
  const after = Number(req.query.after || 0);
  const session = sessions.get(sessionId);
  if (!session) {
    res.status(404).json({ ok: false, error: 'session not found' });
    return;
  }
  const messages = session.signals.filter(
    (m) => m.toDeviceId === deviceId && m.at > after,
  );
  res.json({ ok: true, messages });
});

app.post('/v1/turn/credentials', authMiddleware, (req, res) => {
  if (!TURN_HOST) {
    res.json({
      ok: true,
      iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }],
      note: 'No TURN configured; STUN only. Set GBEAR_TURN_HOST + GBEAR_TURN_SECRET for relay.',
    });
    return;
  }
  const username = `${Math.floor(Date.now() / 1000) + TURN_TTL_SEC}:${req.user.email}`;
  const credential = TURN_SECRET
    ? crypto.createHmac('sha1', TURN_SECRET).update(username).digest('base64')
    : 'anonymous';
  res.json({
    ok: true,
    iceServers: [
      { urls: ['stun:stun.l.google.com:19302'] },
      {
        urls: [`turn:${TURN_HOST}:3478`, `turns:${TURN_HOST}:5349`],
        username,
        credential,
      },
    ],
    ttl: TURN_TTL_SEC,
  });
});

function publicSession(session) {
  return {
    sessionId: session.sessionId,
    ownerEmail: session.ownerEmail,
    hostDeviceId: session.hostDeviceId,
    hostName: session.hostName,
    createdAt: new Date(session.createdAt).toISOString(),
    members: session.members,
  };
}

function broadcast(sessionId, obj) {
  const session = sessions.get(sessionId);
  if (!session) return;
  const payload = JSON.stringify(obj);
  for (const m of session.members) {
    const ws = socketsByDevice.get(m.deviceId);
    if (ws && ws.readyState === 1) ws.send(payload);
  }
}

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/v1/ws' });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const deviceId = url.searchParams.get('deviceId');
  const sessionId = url.searchParams.get('sessionId');
  const mode = url.searchParams.get('mode') || 'signal';
  if (!deviceId) {
    ws.close(4000, 'deviceId required');
    return;
  }
  socketsByDevice.set(deviceId, ws);
  ws.send(JSON.stringify({ type: 'hello', deviceId, sessionId, mode }));

  if (mode === 'relay' && sessionId) {
    const key = sessionId;
    const slot = relays.get(key) || {};
    if (!slot.a) slot.a = ws;
    else if (!slot.b) slot.b = ws;
    relays.set(key, slot);
    const peer = slot.a === ws ? slot.b : slot.a;
    if (peer && peer.readyState === 1) {
      ws.send(JSON.stringify({ type: 'relay_ready' }));
      peer.send(JSON.stringify({ type: 'relay_ready' }));
    }
  }

  ws.on('message', (data, isBinary) => {
    if (mode === 'relay' && sessionId) {
      const slot = relays.get(sessionId);
      if (!slot) return;
      const peer = slot.a === ws ? slot.b : slot.a;
      if (peer && peer.readyState === 1) {
        peer.send(data, { binary: isBinary });
      }
      return;
    }
    try {
      const msg = JSON.parse(String(data));
      if (msg.type === 'signal' && msg.toDeviceId) {
        const target = socketsByDevice.get(msg.toDeviceId);
        if (target && target.readyState === 1) {
          target.send(JSON.stringify({ type: 'signal', ...msg }));
        }
      }
    } catch {
      // ignore
    }
  });

  ws.on('close', () => {
    if (socketsByDevice.get(deviceId) === ws) socketsByDevice.delete(deviceId);
    if (sessionId && mode === 'relay') {
      const slot = relays.get(sessionId);
      if (!slot) return;
      if (slot.a === ws) slot.a = undefined;
      if (slot.b === ws) slot.b = undefined;
      if (!slot.a && !slot.b) relays.delete(sessionId);
    }
  });
});

server.listen(PORT, () => {
  console.log(`[gbear-session] listening on :${PORT} (devAuth=${DEV_AUTH})`);
});
