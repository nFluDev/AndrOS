// AndrOS Signal — iki cihazi tanistirir, sonra aradan cekilir.
//
// Tasarim kurali: sunucu ICERIGI GORMEZ ve HICBIR SEYI DISKE YAZMAZ.
// Elindeki her sey bellekte ve baglanti kapaninca siliniyor. Boyle
// olunca "sunucuya guvenmek" sorusu buyuk olcude ortadan kalkiyor —
// guvenilmesi gereken tek sey, dogru kimlige iletmesi.
import { createServer } from 'node:http';
import { createSocket } from 'node:dgram';
import { createHmac, createHash, randomBytes, verify, createPublicKey } from 'node:crypto';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 3000);
const STUN_PORT = Number(process.env.STUN_PORT || 3478);
const SALT = process.env.SIGNAL_SALT || '';
if (!SALT) {
  console.error('SIGNAL_SALT gerekli. .env dosyasina rastgele bir deger koy.');
  process.exit(1);
}

/** kimlik -> baglanti */
const live = new Map();
/** numara ozeti -> kimlik */
const byNumber = new Map();

const b64 = (buf) => Buffer.from(buf).toString('base64');
const unb64 = (s) => Buffer.from(String(s || ''), 'base64');

/**
 * Acik anahtardan AndrOS kimligi.
 *
 * Crockford base32: okunurken karistirilan harfler (I, L, O, U) yok.
 * Kullanici bunu sesli okuyabilmeli — QR her zaman elde olmuyor.
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
function idFor(pubkey) {
  const h = createHash('sha256').update(pubkey).digest().subarray(0, 10);
  let bits = 0, value = 0, out = '';
  for (const byte of h) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  return out;
}

/// Ed25519 acik anahtari ham 32 bayt geliyor.
///
/// Node ham baytlari kabul etmiyor: DER'e sarip ANAHTAR NESNESI
/// yapmak gerekiyor. Ham tamponu dogrudan `verify`e vermek onu PEM
/// sanip sessizce basarisiz oluyor (olculdu: her imza "badsig").
function ed25519Key(raw) {
  const der = Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(raw),
  ]);
  return createPublicKey({ key: der, format: 'der', type: 'spki' });
}

const http = createServer((req, res) => {
  // Dokploy saglik denetimi ve "ayakta mi" sorusu icin.
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, online: live.size }));
    return;
  }
  res.writeHead(404); res.end();
});

const wss = new WebSocketServer({ server: http, path: '/ws', maxPayload: 256 * 1024 });

wss.on('connection', (ws) => {
  const challenge = randomBytes(32);
  let id = null;
  let numbers = [];
  let alive = true;

  const say = (obj) => { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); };
  say({ t: 'hello', challenge: b64(challenge), v: 1 });

  // Kimligini kanitlamayan baglantiyi tutmuyoruz: acik soket birakmak
  // en ucuz saldiri yuzeyi.
  const authTimer = setTimeout(() => { if (!id) ws.close(); }, 10_000);

  ws.on('message', (raw) => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }

    if (m.t === 'auth') {
      if (id) return;
      const key = unb64(m.key), sig = unb64(m.sig);
      if (key.length !== 32 || sig.length !== 64) return void ws.close();
      let ok = false;
      try { ok = verify(null, challenge, ed25519Key(key), sig); } catch { ok = false; }
      if (!ok) { say({ t: 'error', why: 'badsig' }); return void ws.close(); }
      clearTimeout(authTimer);
      id = idFor(key);
      // Ayni kimlikle ikinci baglanti: eskisini dusur. Telefon aglar
      // arasi gecerken eski soket bir sure "yasiyor" gorunuyor ve
      // paketler oraya gidiyordu.
      const old = live.get(id);
      if (old && old !== ws) { try { old.close(); } catch {} }
      live.set(id, ws);
      numbers = (m.numbers || []).slice(0, 8).map(String);
      for (const n of numbers) byNumber.set(n, id);
      say({ t: 'ready', id });
      return;
    }

    if (!id) return;                     // kanitlamadan hicbir sey yok

    if (m.t === 'lookup') {
      const found = {}, missing = [];
      for (const n of (m.of || []).slice(0, 500)) {
        const who = byNumber.get(String(n));
        if (who && live.has(who)) found[n] = who; else missing.push(String(n));
      }
      say({ t: 'presence', found, missing });
      return;
    }

    if (m.t === 'send') {
      const target = live.get(String(m.to || ''));
      if (!target || target.readyState !== 1) {
        say({ t: 'undeliverable', to: m.to });
        return;
      }
      // Zarf ACILMIYOR, okunmuyor, saklanmiyor — yalnizca iletiliyor.
      target.send(JSON.stringify({ t: 'recv', from: id, env: String(m.env || '') }));
      return;
    }

    if (m.t === 'ping') say({ t: 'pong' });
  });

  ws.on('pong', () => { alive = true; });
  const beat = setInterval(() => {
    if (!alive) { try { ws.terminate(); } catch {} return; }
    alive = false;
    try { ws.ping(); } catch {}
  }, 25_000);

  ws.on('close', () => {
    clearTimeout(authTimer);
    clearInterval(beat);
    if (!id) return;
    if (live.get(id) === ws) live.delete(id);
    for (const n of numbers) if (byNumber.get(n) === id) byNumber.delete(n);
  });
});

/**
 * Kucuk bir STUN sunucusu (RFC 5389 Binding).
 *
 * Kendi sunucumuzda duruyor ki cihazlar dis adreslerini ogrenmek icin
 * baska birinin (Google'in) sunucusuna gitmek zorunda kalmasin.
 */
const stun = createSocket('udp4');
stun.on('message', (msg, rinfo) => {
  if (msg.length < 20) return;
  const type = msg.readUInt16BE(0);
  if (type !== 0x0001) return;                       // yalniz Binding istegi
  const magic = 0x2112a442;
  if (msg.readUInt32BE(4) !== magic) return;
  const txn = msg.subarray(8, 20);

  // XOR-MAPPED-ADDRESS
  const attr = Buffer.alloc(12);
  attr.writeUInt16BE(0x0020, 0);                     // tur
  attr.writeUInt16BE(8, 2);                          // uzunluk
  attr.writeUInt8(0, 4);
  attr.writeUInt8(0x01, 5);                          // IPv4
  attr.writeUInt16BE(rinfo.port ^ (magic >>> 16), 6);
  const ip = rinfo.address.split('.').map(Number);
  const xored = ((ip[0] << 24) | (ip[1] << 16) | (ip[2] << 8) | ip[3]) ^ magic;
  attr.writeUInt32BE(xored >>> 0, 8);

  const res = Buffer.alloc(20 + attr.length);
  res.writeUInt16BE(0x0101, 0);                      // Binding yaniti
  res.writeUInt16BE(attr.length, 2);
  res.writeUInt32BE(magic, 4);
  txn.copy(res, 8);
  attr.copy(res, 20);
  stun.send(res, rinfo.port, rinfo.address);
});
stun.bind(STUN_PORT, () => console.log(`STUN: udp/${STUN_PORT}`));

http.listen(PORT, () => console.log(`AndrOS Signal: http/${PORT} (ws /ws)`));

// Numara ozeti sunucu tarafinda da uretilebilsin diye disari veriyoruz;
// istemciler ayni hesabi kendi yapiyor ve numarayi HIC gondermiyor.
export function digestFor(e164) {
  return createHmac('sha256', SALT).update(e164).digest().subarray(0, 16).toString('base64');
}
