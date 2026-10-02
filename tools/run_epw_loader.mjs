// run_epw_loader.mjs - boot the *real* Eaglercraft EPW loader against a client
//
// The client HTML carries a small wasm "loader" next to the game.  It is the
// code that validates and unpacks the EPW container in the browser, and it is
// the thing that says "EPW file is invalid / Try again later".  This script
// extracts the loader and the EPW from the HTML, then runs the loader against
// the container with the same imports the client's loader.js provides - i.e.
// it performs the same boot the browser performs, just without a DOM.
//
// It catches problems a pure Python check would miss: the loader rejects
// streams whose LZMA2 dictionary exceeds 32 MiB (xz-embedded is built with
// xz_dec_init(XZ_DYNALLOC, 33554432)), and it refuses slices with trailing
// bytes, bad CRCs, out-of-bounds offsets, ...
//
// Usage:
//   node tools/run_epw_loader.mjs client/1.12.html
//   node tools/run_epw_loader.mjs client/1.12.html --dump-epw /tmp/x.epw
//
// exit code 0 = the loader accepted the file ("Loader WASM binary executed
// successfully!"), 1 = it rejected it, 2 = the script could not run.

import fs from 'fs';

const args = process.argv.slice(2);
const input = args.find(a => !a.startsWith('--'));
const dumpIdx = args.indexOf('--dump-epw');
const dumpPath = dumpIdx >= 0 ? args[dumpIdx + 1] : null;

if (!input) {
    console.error('usage: node run_epw_loader.mjs <client.html|file.epw> [--dump-epw FILE]');
    process.exit(2);
}

// --------------------------------------------------------------------------- //
// extract the EPW (and its bundled loader.wasm) from the client
// --------------------------------------------------------------------------- //
function extractEpw(buf) {
    const text = buf.toString('latin1');
    const m = text.match(/assetsURI = "data:application\/octet-stream;base64,([A-Za-z0-9+/=]+)"/);
    if (!m) return buf;                    // assume the file *is* an EPW
    return Buffer.from(m[1], 'base64');
}

const epw = extractEpw(fs.readFileSync(input));
if (epw.subarray(0, 8).toString('latin1') !== 'EAG$WASM') {
    console.error('not an EPW file (bad magic)');
    process.exit(2);
}
const u32 = off => epw.readUInt32LE(off);
const loaderWasm = epw.subarray(u32(180), u32(180) + u32(184));
if (dumpPath) fs.writeFileSync(dumpPath, epw);

// --------------------------------------------------------------------------- //
// the imports loader.js gives the loader (see the client's EPW text)
// --------------------------------------------------------------------------- //
const results = [null];        // the real glue pre-seeds this so ids start at 1
let memory, heap;
let failed = null, success = false, jspiScreen = false;

function cstr(ptr) {
    let end = ptr;
    while (end < heap.length && heap[end]) end++;
    return Buffer.from(heap.subarray(ptr, end)).toString('utf8');
}

const imports = {
    k: (dest, src, len) => { heap.copyWithin(dest, src, src + len); },          // memory move
    c: ptr => { console.error('LoaderMain: [ERROR] ' + (ptr ? cstr(ptr) : '')); },   // dbgErr
    b: ptr => { console.log('LoaderMain: [INFO] ' + (ptr ? cstr(ptr) : '')); },      // dbgLog
    j: want => {                                                                // grow memory
        try {
            memory.grow(Math.ceil((want - memory.buffer.byteLength) / 65536));
            heap = new Uint8Array(memory.buffer);
            return 1;
        } catch (e) { return 0; }
    },
    n: () => epw.length,                                                        // getEPWLength
    i: () => 1,                        // getJSPISupported (Chrome has JSPI; 1 = normal path)
    f: (off, len) => { const id = results.length; results.push(epw.subarray(off, off + len)); return id; },
    e: len => { const id = results.length; results.push(new Uint8Array(len)); return id; },
    d: (dest, off, len) => { heap.set(epw.subarray(off, off + len), dest); },    // memcpyFromEPW
    g: (id, destOff, off, len) => { results[id].set(epw.subarray(off, off + len), destOff); },
    l: (id, src, destOff, len) => { results[id].set(heap.subarray(src, src + len), destOff); },
    a: ptr => { failed = cstr(ptr); },                                          // resultFailed
    h: () => { jspiScreen = true; },                                            // resultJSPIUnsupported
    m: () => { success = true; },                                               // resultSuccess
};

const { instance } = await WebAssembly.instantiate(loaderWasm, { a: imports });
memory = instance.exports.o;
heap = new Uint8Array(memory.buffer);

// export "q" is _main, "s" is malloc, "p" is call_ctors (per loader.js)
const main = instance.exports.q;
if (typeof main !== 'function') {
    console.error('loader.wasm has no main export');
    process.exit(2);
}
try { main(); } catch (e) { failed = failed || String(e); }

const filled = results.filter(b => b && b.length && b.some(x => x !== 0)).length;
console.log('---');
console.log('EPW size                :', epw.length);
console.log('components materialized :', results.length - 1, '(' + filled + ' non-empty)');
console.log('resultFailed            :', failed === null ? 'no' : JSON.stringify(failed));
console.log('resultSuccess           :', success);
console.log(failed === null && success ? 'LOADER VERDICT: OK' : 'LOADER VERDICT: FAILED');
process.exit(failed === null && success ? 0 : 1);
