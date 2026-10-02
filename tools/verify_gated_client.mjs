// verify_gated_client.mjs - prove the gated client actually works
//
// Runs the real gate script from client/1.12.html in a headless DOM, exactly
// like a browser would:
//
//   * main() before login must NOT start the game (the payload is sealed)
//   * a wrong username/password must be rejected
//   * the right credentials must unseal the EPW and only then boot the game
//   * the unsealed payload must be the valid EPW the real loader accepts
//   * the plaintext credentials must not be anywhere in the file
//
// usage:
//   node tools/verify_gated_client.mjs client/1.12.html --user sllab --pass reggin
//   VER_CLIENT_USER=sllab VER_CLIENT_PASS=reggin node tools/verify_gated_client.mjs
//
// --dump-epw FILE also writes the unsealed container out, so the client's own
// loader can be tested against exactly what a player's browser would get.
//
// The credentials are only ever passed in, never stored in the repo or the file.

import fs from 'fs';
import vm from 'vm';
import { webcrypto, pbkdf2Sync, createHash } from 'crypto';
import { runLoader, isEpw } from './run_epw_loader.mjs';

const args = process.argv.slice(2);
const input = args.find(a => !a.startsWith('--')) || 'client/1.12.html';
const opt = name => {
    const i = args.indexOf('--' + name);
    return i >= 0 ? args[i + 1] : undefined;
};
const user = opt('user') || process.env.VER_CLIENT_USER;
const pass = opt('pass') || process.env.VER_CLIENT_PASS;
if (!user || !pass) {
    console.error('need credentials: --user/--pass or VER_CLIENT_USER/VER_CLIENT_PASS');
    process.exit(2);
}

const html = fs.readFileSync(input);
const text = html.toString('utf8');
const expectedBrand = opt('brand') || process.env.VER_CLIENT_BRAND;

// the brand UUID the server checks: UUID.nameUUIDFromBytes("EaglercraftXClient:"+brand)
function brandUuid(brand) {
    const h = createHash('md5').update('EaglercraftXClient:' + brand, 'utf8').digest();
    h[6] = (h[6] & 0x0f) | 0x30;
    h[8] = (h[8] & 0x3f) | 0x80;
    const hex = h.toString('hex');
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
}

let pass_ = 0, fail = 0;
const check = (name, ok, extra = '') => {
    if (ok) { pass_++; console.log('  ok   - ' + name); }
    else { fail++; console.log('  FAIL - ' + name + (extra ? ' (' + extra + ')' : '')); }
};

// --------------------------------------------------------------------------- //
// 1. the file itself must not leak anything
// --------------------------------------------------------------------------- //
console.log('== the file');
check('contains a login gate', text.includes('/* verified-client gate */'));
check('the payload is sealed, not a plaintext EPW data URI',
    !text.includes('assetsURI = "data:application/octet-stream;base64,'));
// the sealed payload is random ciphertext: a short credential can appear in it
// by pure chance, so the file is checked with that blob taken out
const withoutPayload = text.replace(/window\.__verSealed = "[A-Za-z0-9+/=]*";/,
                                    'window.__verSealed = "<sealed>";');
check('the plaintext username is not in the file (sealed payload excluded)',
    !withoutPayload.includes(user));
check('the plaintext password is not in the file (sealed payload excluded)',
    !withoutPayload.includes(pass));
// the brand is NOT written in the file: only a PBKDF2 verifier of it, so the
// file can be checked against a brand without publishing it
const kdf = text.match(/brandKdf:\s*\{\s*salt:\s*"([0-9a-f]+)",\s*iter:\s*(\d+),\s*hash:\s*"([0-9a-f]+)"\s*\}/);
check('the file carries a brand verifier (PBKDF2-SHA512)', !!kdf);
check('the file does not publish the brand in plain text', !/brand: "/.test(text));
if (expectedBrand) {
    const inFile = text.includes(expectedBrand);
    check('the expected brand is nowhere in the file', !inFile);
}
if (kdf) {
    const verifier = { salt: kdf[1], iter: parseInt(kdf[2], 10), hash: kdf[3] };
    console.log(`        brand verifier: ${verifier.iter} iterations, ${verifier.hash.slice(0, 16)}...`);
    if (expectedBrand) {
        const got = pbkdf2Sync(expectedBrand, Buffer.from(verifier.salt, 'hex'), verifier.iter, 32, 'sha512').toString('hex');
        check('…and it matches the expected brand', got === verifier.hash);
        console.log('        expected brand uuid: ' + brandUuid(expectedBrand));
    }
}

// --------------------------------------------------------------------------- //
// 2. run the gate in a headless DOM
// --------------------------------------------------------------------------- //
class FakeEl {
    constructor(tag) { this.tagName = tag; this.children = []; this.style = { cssText: '' }; this.listeners = {}; }
    appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
    removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentNode = null; return c; }
    addEventListener(k, fn) { (this.listeners[k] = this.listeners[k] || []).push(fn); }
    focus() { }
    set textContent(v) { this._text = v; }
    get textContent() { return this._text; }
}
const ids = {};
const body = new FakeEl('body');
const document = {
    body,
    documentElement: new FakeEl('html'),
    createElement: tag => new FakeEl(tag),
    createTextNode: t => ({ nodeType: 3, text: t }),
    getElementById: id => ids[id] || null,
};

const gateCode = text.slice(text.indexOf('<script>/* verified-client gate */') + 8,
    text.indexOf('</script>', text.indexOf('/* verified-client gate */')));
if (!gateCode) { console.error('could not extract the gate script'); process.exit(2); }

let bootCalls = 0;
const sandbox = {
    console: { log() { }, warn() { }, error() { } },
    crypto: webcrypto, TextEncoder, Blob, atob, btoa,
    Promise, setTimeout, clearTimeout, Date, Math, parseInt, String, Object, Error,
    Uint8Array, Array, JSON, isNaN, encodeURIComponent,
    document,
    eaglercraftXOpts: { container: 'game_frame' },
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.main = async function () { bootCalls++; };
sandbox.__verSealed = undefined;                    // filled in by the page below

// the sealed payload lives in the page just before the gate
const sealedMatch = text.match(/window\.__verSealed = "([A-Za-z0-9+/=]+)"/);
if (!sealedMatch) { console.error('no sealed payload found'); process.exit(2); }
sandbox.__verSealed = sealedMatch[1];

vm.createContext(sandbox);
vm.runInContext(gateCode, sandbox);
const gate = sandbox.__verGate;
check('the gate installs itself', !!gate);
check('window.main is wrapped by the gate', typeof sandbox.main === 'function');

console.log('== booting without logging in');
sandbox.main();
check('the game does not boot before login', bootCalls === 0);
check('the login form is shown', gate.state().visible === true);

console.log('== wrong credentials');
const wrong = await gate.submit(user, pass + 'x');
check('a wrong password is rejected', wrong === false);
check('…and still nothing boots', bootCalls === 0 && gate.state().ready === false);
const wrongUser = await gate.submit(user + 'x', pass);
check('a wrong username is rejected', wrongUser === false);
check('…with the payload still sealed', gate.state().ready === false);

console.log('== the right credentials');
const ok = await gate.submit(user, pass);
check('the credentials are accepted', ok === true);
check('the client boots exactly once', bootCalls === 1);
const uri = sandbox.eaglercraftXOpts.assetsURI;
check('the EPW data URI was produced', typeof uri === 'string' && uri.startsWith('data:application/octet-stream;base64,'));
check('the sealed copy was dropped from the page', sandbox.__verSealed === null);
check('calling main() again does not double boot', (sandbox.main(), bootCalls === 1));

// --------------------------------------------------------------------------- //
// 3. the unsealed payload must be a real, loadable EPW
// --------------------------------------------------------------------------- //
console.log('== the unsealed payload');
const epw = Buffer.from(uri.split(',')[1], 'base64');
check('it is an EPW container', isEpw(epw));
const dumpEpw = opt('dump-epw');
if (dumpEpw) {
    fs.writeFileSync(dumpEpw, epw);
    console.log('        unsealed EPW written to ' + dumpEpw);
}
const r = runLoader(epw, { quiet: true });
check('the client\'s own loader accepts it', r.ok === true, r.failure || '');
const find = needle => r.results.some(b => {
    if (typeof b === 'string') return b.includes(needle);
    return b && b.length && Buffer.from(b).toString('latin1').includes(needle);
});
const sizes = r.results.map(b => b && b.length).filter(Boolean).sort((a, b) => b - a).slice(0, 4);
console.log('        biggest components:', sizes.join(', '), 'bytes');
check('classes.wasm came out of the loader', find(String.fromCharCode(0) + 'asm'));
const claimed = expectedBrand || '';
// the brand the *server* sees is the 16 byte string-pool entry right before
// "EaglercraftXClientOld:" - check that exact slot, not the game's own texts
const brandSlot = (() => {
    for (const b of r.results) {
        if (typeof b === 'string' || !b || !b.length) continue;
        const txt = Buffer.from(b).toString('latin1');
        const i = txt.indexOf('EaglercraftXClientOld:');
        if (i >= 19 && txt.charCodeAt(i - 18) === 16 && txt.charCodeAt(i - 1) === 22) return txt.substr(i - 17, 16);
    }
    return null;
})();
console.log('        brand slot in classes.wasm:', JSON.stringify(brandSlot));
if (brandSlot) console.log('        -> brand UUID the server sees: ' + brandUuid(brandSlot));
if (kdf && brandSlot) {
    const verifier = { salt: kdf[1], iter: parseInt(kdf[2], 10), hash: kdf[3] };
    const got = pbkdf2Sync(brandSlot, Buffer.from(verifier.salt, 'hex'), verifier.iter, 32, 'sha512').toString('hex');
    check('the brand inside the payload matches the file\'s verifier', got === verifier.hash);
}
if (claimed) check('the payload carries the expected brand', brandSlot === claimed, String(brandSlot));
check('the revoked brand is gone from the payload', brandSlot !== 'Eaglercraft[VER]' && !find('Eaglercraft[VER]XClientOld'));
check('…and the stock brand is not used', brandSlot !== 'Eaglercraft 1.12');

console.log('');
console.log(`passed: ${pass_}  failed: ${fail}`);
if (fail === 0) console.log(`ALL CHECKS PASSED (${pass_}/${pass_})`);
process.exit(fail === 0 ? 0 : 1);
