// run_epw_loader.mjs - boot the *real* Eaglercraft EPW loader against a client
//
// The client HTML carries a small wasm "loader" next to the game.  It is the
// code that validates and unpacks the EPW container in the browser, and it is
// the thing that says "EPW file is invalid / Try again later".  This module
// extracts the loader and the EPW, then runs the loader with the imports the
// client's loader.js provides - i.e. the same boot the browser performs, just
// without a DOM.
//
// It catches problems a pure Python check would miss: the loader rejects
// streams whose LZMA2 dictionary exceeds 32 MiB (xz-embedded is built with
// xz_dec_init(XZ_DYNALLOC, 33554432)), slices with trailing bytes, bad CRCs,
// out-of-bounds offsets, ...
//
// CLI:
//   node tools/run_epw_loader.mjs client/1.12.html
//   node tools/run_epw_loader.mjs client/1.12.html --dump-epw /tmp/x.epw
//   node tools/run_epw_loader.mjs /tmp/x.epw
//
// Module:
//   import { runLoader, extractEpwFromHtml, loaderWasmFrom } from './run_epw_loader.mjs'
//   const r = runLoader(epwBuffer);      // r.ok, r.failure, r.results, r.logs
//
// exit code 0 = the loader accepted the file, 1 = it rejected it, 2 = could not run.

import fs from 'fs';
import { pathToFileURL } from 'url';

const ASSETS_URI_RE = /assetsURI = "data:application\/octet-stream;base64,([A-Za-z0-9+/=]+)"/;

export function extractEpwFromHtml(text) {
    const m = text.match(ASSETS_URI_RE);
    return m ? Buffer.from(m[1], 'base64') : null;
}

export function loaderWasmFrom(epw) {
    return epw.subarray(epw.readUInt32LE(180), epw.readUInt32LE(180) + epw.readUInt32LE(184));
}

export function isEpw(buf) {
    return buf.length > 384 && buf.subarray(0, 8).toString('latin1') === 'EAG$WASM';
}

// Run the loader in-process.  It is a wasm module with a linear memory the
// loader itself grows, and the "imports" below are what loader.js passes it.
export function runLoader(epwBuffer, opts = {}) {
    const loaderWasm = loaderWasmFrom(epwBuffer);
    const results = [null];          // the real glue pre-seeds this so ids start at 1
    let memory = null, heap = null, failed = null, success = false;
    const logs = [];
    const cstr = ptr => {
        let end = ptr;
        while (end < heap.length && heap[end]) end++;
        return Buffer.from(heap.subarray(ptr, end)).toString('utf8');
    };
    const say = (line, err) => {
        logs.push(line);
        if (err) console.error(line);
        else if (!opts.quiet) console.log(line);
    };
    const imports = {
        k: (dest, src, len) => { heap.copyWithin(dest, src, src + len); },        // memmove
        c: ptr => say('LoaderMain: [ERROR] ' + (ptr ? cstr(ptr) : ''), true),      // dbgErr
        b: ptr => say('LoaderMain: [INFO] ' + (ptr ? cstr(ptr) : '')),             // dbgLog
        j: want => {                                                              // grow memory
            try {
                memory.grow(Math.ceil((want - memory.buffer.byteLength) / 65536));
                heap = new Uint8Array(memory.buffer);
                return 1;
            } catch (e) { return 0; }
        },
        n: () => epwBuffer.length,                                                // getEPWLength
        i: () => 1,                      // getJSPISupported: 1 = normal, non-JSPI path
        // argument orders are from the client's own loader.js:
        //   f(off,len)              -> push a decoded string result
        //   e(len)                  -> push an empty byte result
        //   d(heapDest,epwOff,len)  -> copy from the EPW into the heap
        //   g(id,destOff,epwOff,len)
        //   l(id,srcHeapOff,len,destOff)   <- note: length *before* dest
        f: (off, len) => {
            const id = results.length;
            results.push(new TextDecoder().decode(epwBuffer.subarray(off, off + len)));
            return id;
        },
        e: len => { const id = results.length; results.push(new Uint8Array(len)); return id; },
        d: (dest, off, len) => { heap.set(epwBuffer.subarray(off, off + len), dest); },
        g: (id, destOff, off, len) => { results[id].set(epwBuffer.subarray(off, off + len), destOff); },
        l: (id, src, len, destOff) => { results[id].set(heap.subarray(src, src + len), destOff); },
        a: ptr => { failed = cstr(ptr); },                                        // resultFailed
        h: () => { logs.push('JSPI unsupported screen'); },                        // resultJSPIUnsupported
        m: () => { success = true; },                                             // resultSuccess
    };
    const instance = new WebAssembly.Instance(new WebAssembly.Module(loaderWasm), { a: imports });
    memory = instance.exports.o;
    heap = new Uint8Array(memory.buffer);
    const entry = instance.exports.q;                 // q == _main
    if (typeof entry !== 'function') throw new Error('loader.wasm has no main export');
    try { entry(); } catch (e) { failed = failed || String(e); }
    return { ok: failed === null && success, failure: failed, success, results: results.slice(1), logs };
}

function main() {
    const args = process.argv.slice(2);
    const input = args.find(a => !a.startsWith('--'));
    const dumpIdx = args.indexOf('--dump-epw');
    const dumpPath = dumpIdx >= 0 ? args[dumpIdx + 1] : null;
    if (!input) {
        console.error('usage: node run_epw_loader.mjs <client.html|file.epw> [--dump-epw FILE]');
        process.exit(2);
    }
    const raw = fs.readFileSync(input);
    const epw = extractEpwFromHtml(raw.toString('latin1')) || raw;
    if (!isEpw(epw)) {
        console.error('not an EPW file (bad magic) - is this a gated client?');
        process.exit(2);
    }
    if (dumpPath) fs.writeFileSync(dumpPath, epw);
    const r = runLoader(epw);
    const filled = r.results.filter(b => {
        if (typeof b === 'string') return b.length > 0;
        return b && b.length && b.some(x => x !== 0);
    }).length;
    console.log('---');
    console.log('EPW size                :', epw.length);
    console.log('components materialized :', r.results.length, '(' + filled + ' non-empty)');
    console.log('resultFailed            :', r.failure === null ? 'no' : JSON.stringify(r.failure));
    console.log('resultSuccess           :', r.success);
    console.log(r.ok ? 'LOADER VERDICT: OK' : 'LOADER VERDICT: FAILED');
    process.exit(r.ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main();
}
