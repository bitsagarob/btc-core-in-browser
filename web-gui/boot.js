// Loader for Bitcoin Core compiled to WebAssembly.
//
// Lives in its own file rather than inline so the page can run under a Content
// Security Policy with no 'unsafe-inline' in script-src.
(function () {
  var boot = document.getElementById('boot');
  var fail = document.getElementById('fail');

  // Page view only, through bitsaga.be's same-origin /mt.php proxy: COEP blocks
  // the analytics host directly, because it sends no Cross-Origin-Resource-Policy.
  // Nothing is sent when this page is served from anywhere else, so a clone is
  // silent by default.
  if (location.hostname === 'bitsaga.be') {
    window._paq = window._paq || [];
    window._paq.push(['setDocumentTitle', 'Bitcoin Core in your browser']);
    window._paq.push(['setTrackerUrl', '/mt.php']);
    window._paq.push(['setSiteId', '1']);
    window._paq.push(['trackPageView']);
    var mt = document.createElement('script');
    mt.async = true;
    mt.src = '/mt.js';
    document.getElementsByTagName('script')[0].parentNode.insertBefore(mt, null);
  }

  // ------------------------------------------------------------------ gating
  // Decided before any fetch, so a phone costs nothing. All three signals have
  // to agree: a touchscreen laptop trips two of them, and screen.width is in CSS
  // pixels, so a 1080p laptop at 200% OS scaling reports 540.
  function looksLikeAPhone() {
    if (navigator.userAgentData && typeof navigator.userAgentData.mobile === 'boolean') {
      return navigator.userAgentData.mobile;
    }
    var coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
    var touch = navigator.maxTouchPoints > 1;
    var narrow = Math.min(window.screen.width, window.screen.height) < 700;
    return coarse && touch && narrow;
  }

  if (looksLikeAPhone() && location.hash !== '#anyway') {
    document.body.classList.add('mobile');
    return;
  }

  // ---------------------------------------------------------------- progress
  function step(id) {
    var el = document.getElementById(id);
    return {
      el: el,
      bar: el.querySelector('.bar'),
      pct: el.querySelector('.step-pct'),
      start: function () { el.classList.remove('pending'); },
      spin: function () { this.bar.classList.add('indeterminate'); },
      set: function (loaded, total) {
        // Once per tenth of a percent. Per chunk is ~3400 layout-triggering
        // writes on the thread that is about to compile 55 MB of wasm.
        var pct = total ? (100 * loaded / total).toFixed(1) : '0.0';
        if (pct === this.last) return;
        this.last = pct;
        this.bar.classList.remove('indeterminate');
        this.bar.style.width = pct + '%';
        this.bar.setAttribute('aria-valuenow', pct);
        this.pct.textContent = mb(loaded) + ' / ' + mb(total);
      },
      done: function (label) {
        this.bar.classList.remove('indeterminate');
        this.bar.style.width = '100%';
        el.classList.remove('pending');
        el.classList.add('done');
        this.pct.textContent = label || '';
      }
    };
  }

  function mb(n) { return (n / 1048576).toFixed(1) + ' MB'; }

  function die(text, err) {
    if (err) console.error(err);
    document.body.classList.add('failed');
    boot.style.display = 'flex';
    fail.style.display = 'block';
    fail.textContent = text;
    var bars = document.querySelectorAll('.bar');
    for (var i = 0; i < bars.length; i++) bars[i].classList.remove('indeterminate');
  }

  var sWasm = step('s-wasm'), sData = step('s-data'), sStart = step('s-start');

  if (!window.crossOriginIsolated) {
    die('This page is not cross-origin isolated, so the browser withholds SharedArrayBuffer '
      + 'and Bitcoin Core cannot start its script verification threads. The server has to '
      + 'send Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: '
      + 'require-corp on this path.');
    return;
  }

  // The files are served pre-compressed, so Content-Length is the compressed
  // size while the stream yields decompressed bytes. manifest.json carries the
  // decompressed sizes, so the bar is honest.
  function fetchWithProgress(url, total, ui) {
    return fetch(url).then(function (res) {
      if (!res.ok) throw new Error(url + ' returned ' + res.status);
      var known = total || parseInt(res.headers.get('content-length') || '0', 10);
      if (!known || !res.body) { ui.spin(); return res.arrayBuffer(); }
      // Written straight into one buffer of the known size. Collecting chunks
      // and concatenating afterwards doubles peak memory, and the 55 MB
      // contiguous allocation is the one most likely to fail.
      var reader = res.body.getReader();
      var out = new Uint8Array(known);
      var received = 0;
      ui.set(0, known);
      return (function pump() {
        return reader.read().then(function (r) {
          if (r.done) return out.buffer;
          out.set(r.value, received);
          received += r.value.length;
          ui.set(Math.min(received, known), known);
          return pump();
        });
      })();
    });
  }


  fetch('manifest.json')
    .then(function (r) {
      if (!r.ok) throw new Error('manifest.json returned ' + r.status);
      return r.json();
    })
    .then(function (m) {
      sWasm.start();
      return fetchWithProgress(m.wasm, m.wasmSize, sWasm).then(function (wasm) {
        sWasm.done(mb(wasm.byteLength));
        sData.start();
        return fetchWithProgress(m.data, m.dataSize, sData).then(function (data) {
          sData.done(mb(data.byteLength));
          return { wasm: wasm, data: data, js: m.js };
        });
      });
    })
    .then(function (blobs) {
      sStart.start();
      sStart.spin();

      window.Module = {
        arguments: ['-regtest', '-datadir=/data', '-connect=0', '-listen=0',
                    '-dnsseed=0', '-wallet=bench', '-printtoconsole=1',
                    // The chain is baked in and its tip never moves. Without
                    // this Core decides it is still in initial block download.
                    '-maxtipage=3153600000'],
        qtContainerElements: [document.getElementById('screen')],
        preRun: [function () { try { FS.mkdir('/data'); } catch (e) {} }],

        // The bytes are handed over and then dropped: Emscripten copies both
        // into the wasm heap, and holding a second 74 MB for the session is the
        // difference between working and not on a laptop with other tabs open.
        instantiateWasm: function (imports, successCallback) {
          WebAssembly.instantiate(blobs.wasm, imports).then(function (out) {
            blobs.wasm = null;
            successCallback(out.instance, out.module);
          }).catch(function (e) { die('WebAssembly failed to start.', e); });
          return {};
        },
        getPreloadedPackage: function () {
          var d = blobs.data;
          blobs.data = null;
          return d;
        },

        onRuntimeInitialized: function () {
          sStart.done();
          setTimeout(function () { boot.style.display = 'none'; }, 3500);
        },
        onAbort: function (what) { die('Bitcoin Core stopped: ' + what, what); }
      };

      var s = document.createElement('script');
      s.src = blobs.js;
      s.onerror = function () { die('Could not load ' + blobs.js); };
      document.body.appendChild(s);
    })
    .catch(function (e) { die('Could not start: ' + e.message, e); });
})();
