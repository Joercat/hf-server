/* ---------------------------------------------------------------------------
 * Verified client gate (tools/patch_verified_client.py)
 *
 * The EPW payload is sealed with AES-256-GCM under a key derived from the
 * username + password with PBKDF2-HMAC-SHA512.  Nothing here contains the
 * credentials, and without them the file cannot produce a working client:
 * there is no plaintext EPW anywhere in the page.
 *
 * The whole client boots through `window.main`, so wrapping that is enough to
 * hold the game back until the payload is unsealed.  Placeholders are filled
 * in by the patcher:
 *
 *   %ITER%   PBKDF2 iterations        %SALT%  hex salt
 *   %IV%     96 bit GCM IV (hex)      %BRAND% / %UUID%  markers (not secret)
 * ------------------------------------------------------------------------- */
(function () {
    "use strict";
    var W = window, D = document, C = W.crypto;
    var M = W.main;                       // the real entry point
    if (typeof M !== "function") { return; }
    var S = W.__verSealed;                // the sealed EPW (base64)
    if (typeof S !== "string") { return; }

    var ITER = %ITER%;
    var SALT = "%SALT%", IV = "%IV%";
    var LIMIT = 5, LOCK = 30000;

    var ready = false, booted = false, shown = false, busy = false;
    var fails = 0, lockUntil = 0, payload = null;
    var root, uBox, pBox, btn, msg;

    function hex(s) {
        for (var a = new Uint8Array(s.length >> 1), i = 0; i < a.length; i++) {
            a[i] = parseInt(s.substr(i * 2, 2), 16);
        }
        return a;
    }

    function b64(s) {
        var bin = atob(s), a = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) { a[i] = bin.charCodeAt(i); }
        return a;
    }

    function el(kind, css, text) {
        var e = D.createElement(kind);
        if (css) { e.style.cssText = css; }
        if (text != null) { e.appendChild(D.createTextNode(text)); }
        return e;
    }

    function build() {
        if (shown) { return; }
        shown = true;
        var box = el("div", "position:fixed;inset:0;z-index:2147483647;background:#0d0d10;" +
            "display:flex;align-items:center;justify-content:center;font-family:sans-serif;color:#e8e8ee");
        var card = el("div", "background:#16161c;border:1px solid #2a2a35;border-radius:12px;" +
            "padding:34px 30px;width:320px;box-shadow:0 18px 50px rgba(0,0,0,.6)");
        var title = el("div", "font-size:22px;font-weight:700;letter-spacing:.5px;margin-bottom:4px", "Eaglercraft[VER]");
        var sub = el("div", "font-size:12px;color:#8a8a9a;margin-bottom:22px", "This client is private. Sign in to continue.");
        var lab1 = el("div", "font-size:12px;color:#8a8a9a;margin:0 0 6px", "Username");
        uBox = el("input", "width:100%;box-sizing:border-box;padding:10px;border-radius:7px;" +
            "border:1px solid #33333f;background:#0f0f14;color:#fff;font-size:14px;outline:none");
        uBox.type = "text"; uBox.autocomplete = "off"; uBox.spellcheck = false;
        var lab2 = el("div", "font-size:12px;color:#8a8a9a;margin:14px 0 6px", "Password");
        pBox = el("input", "width:100%;box-sizing:border-box;padding:10px;border-radius:7px;" +
            "border:1px solid #33333f;background:#0f0f14;color:#fff;font-size:14px;outline:none");
        pBox.type = "password";
        btn = el("button", "width:100%;margin-top:20px;padding:11px;border:0;border-radius:7px;" +
            "background:#3a5bd9;color:#fff;font-size:14px;font-weight:600;cursor:pointer", "Sign in");
        msg = el("div", "font-size:12px;color:#e0555f;margin-top:12px;min-height:16px");
        card.appendChild(title); card.appendChild(sub);
        card.appendChild(lab1); card.appendChild(uBox);
        card.appendChild(lab2); card.appendChild(pBox);
        card.appendChild(btn); card.appendChild(msg);
        box.appendChild(card);
        (D.body || D.documentElement).appendChild(box);
        root = box;
        btn.addEventListener("click", function () { submit(uBox.value, pBox.value); });
        pBox.addEventListener("keydown", function (e) { if (e.key === "Enter") { submit(uBox.value, pBox.value); } });
        uBox.addEventListener("keydown", function (e) { if (e.key === "Enter") { pBox.focus(); } });
        try { uBox.focus(); } catch (e) { }
    }

    function say(text, colour) {
        if (msg) { msg.style.color = colour || "#e0555f"; msg.textContent = text || ""; }
    }

    function toDataURI(bytes) {
        var blob = new Blob([bytes], { type: "application/octet-stream" });
        return new Promise(function (done) {
            try {
                var r = new FileReader();
                r.onload = function () { done(r.result); };
                r.onerror = function () { done(slow(bytes)); };
                r.readAsDataURL(blob);
            } catch (e) { done(slow(bytes)); }
        });
        function slow(b) {                     // no FileReader: encode by hand
            var CH = 0x8000, out = [];
            for (var i = 0; i < b.length; i += CH) {
                out.push(String.fromCharCode.apply(null, b.subarray(i, i + CH)));
            }
            return "data:application/octet-stream;base64," + btoa(out.join(""));
        }
    }

    function unseal(user, pass) {
        var enc = new TextEncoder();
        return C.subtle.importKey("raw", enc.encode(user + "\u0000" + pass), "PBKDF2", false, ["deriveKey"])
            .then(function (base) {
                return C.subtle.deriveKey(
                    { name: "PBKDF2", salt: hex(SALT), iterations: ITER, hash: "SHA-512" },
                    base, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
            })
            .then(function (key) {
                return C.subtle.decrypt({ name: "AES-GCM", iv: hex(IV) }, key, b64(S));
            });
    }

    function submit(user, pass) {
        if (busy || ready) { return Promise.resolve(false); }
        if (Date.now() < lockUntil) {
            say("Too many attempts. Try again in " + Math.ceil((lockUntil - Date.now()) / 1000) + "s.");
            return Promise.resolve(false);
        }
        if (!user || !pass) { say("Enter your username and password."); return Promise.resolve(false); }
        if (!C || !C.subtle) {
            say("This browser has no WebCrypto. Open the client over https in a modern browser.");
            return Promise.resolve(false);
        }
        busy = true;
        if (btn) { btn.disabled = true; }
        say("Checking\u2026", "#8a8a9a");
        return unseal(user, pass).then(function (buf) {
            var bytes = new Uint8Array(buf);
            if (bytes.length < 16 || bytes[0] !== 0x45 || bytes[1] !== 0x41 ||
                bytes[2] !== 0x47 || bytes[3] !== 0x24) {
                throw new Error("bad payload");
            }
            return toDataURI(bytes).then(function (uri) {
                payload = uri;
                ready = true;
                busy = false;
                say("Welcome back \u2014 starting\u2026", "#4fd07a");
                if (!booted) { boot(); }
                return true;
            });
        })["catch"](function () {
            busy = false;
            if (btn) { btn.disabled = false; }
            fails++;
            if (fails >= LIMIT) { lockUntil = Date.now() + LOCK; fails = 0; }
            try { if (pBox) { pBox.value = ""; pBox.focus(); } } catch (e) { }
            say("Wrong username or password.");
            return false;
        });
    }

    function boot() {
        if (booted || !ready) { return false; }
        booted = true;
        if (root && root.parentNode) { root.parentNode.removeChild(root); }
        var splash = D.getElementById("launch_countdown_screen");
        if (splash && splash.parentNode) { splash.parentNode.removeChild(splash); }
        W.eaglercraftXOpts = W.eaglercraftXOpts || {};
        W.eaglercraftXOpts.assetsURI = payload;
        W.__verSealed = null;
        return M();
    }

    W.main = function () {
        if (booted) { return void 0; }
        if (ready) { return boot(); }
        build();
        return void 0;
    };

    W.__verGate = {
        brand: "%BRAND%", uuid: "%UUID%",
        submit: function (u, p) { return submit(u, p); },
        state: function () { return { ready: ready, booted: booted, visible: shown, fails: fails }; }
    };
})();
