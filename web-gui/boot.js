// Loader for Bitcoin Core compiled to WebAssembly.
//
// Lives in its own file rather than inline so the page can run under a Content
// Security Policy with no 'unsafe-inline' in script-src.
(function () {
  var boot = document.getElementById('boot');
  var fail = document.getElementById('fail');

  // ---------------------------------------------------------------- analytics
  // Same Matomo instance and site id the rest of bitsaga.be uses. This page has
  // no shared footer, so the snippet is repeated here rather than included.
  //
  // The URLs are same-origin on purpose. This page is served with
  // Cross-Origin-Embedder-Policy: require-corp, which it needs in order to be
  // cross-origin isolated, and which blocks any cross-origin subresource that
  // does not send Cross-Origin-Resource-Policy. analytics.bitsaga.be sends none,
  // so loading it directly fails silently and nothing is ever recorded. nginx
  // proxies m.js and m.php to it from this path instead.
  window._paq = window._paq || [];
  var paq = window._paq;
  paq.push(['setDocumentTitle', 'Bitcoin Core in your browser']);
  paq.push(['trackPageView']);
  paq.push(['enableLinkTracking']);
  (function () {
    paq.push(['setTrackerUrl', 'm.php']);
    paq.push(['setSiteId', '1']);
    var d = document, g = d.createElement('script'), s = d.getElementsByTagName('script')[0];
    g.async = true;
    g.src = 'm.js';
    s.parentNode.insertBefore(g, s);
  })();

  function track(action, name) {
    if (window._paq) window._paq.push(['trackEvent', 'Bitcoin Core wasm', action, name]);
  }

  // ------------------------------------------------------------------ gating
  // A phone cannot usefully run a desktop Qt application, and the download is
  // large enough that starting it anyway would be rude. Decided before any
  // fetch, so a phone costs nothing.
  var coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
  var narrow = Math.min(window.screen.width, window.screen.height) < 700;
  var touch = navigator.maxTouchPoints > 1;
  if ((coarse && touch) || narrow) {
    document.body.classList.add('mobile');
    track('Blocked', 'Mobile device');
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
        this.bar.classList.remove('indeterminate');
        this.bar.style.width = (total ? (100 * loaded / total) : 0).toFixed(1) + '%';
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

  function die(text, reason) {
    fail.style.display = 'block';
    fail.textContent = text;
    var bars = document.querySelectorAll('.bar');
    for (var i = 0; i < bars.length; i++) bars[i].classList.remove('indeterminate');
    track('Failed', reason || text.slice(0, 60));
  }

  var sWasm = step('s-wasm'), sData = step('s-data'), sStart = step('s-start');

  if (!window.crossOriginIsolated) {
    die('This page is not cross-origin isolated, so the browser withholds SharedArrayBuffer '
      + 'and Bitcoin Core cannot start its script verification threads. The server has to '
      + 'send Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: '
      + 'require-corp on this path.', 'Not cross-origin isolated');
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
      var reader = res.body.getReader();
      var chunks = [], received = 0;
      ui.set(0, known);
      return (function pump() {
        return reader.read().then(function (r) {
          if (r.done) {
            var out = new Uint8Array(received), at = 0;
            for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], at); at += chunks[i].length; }
            return out.buffer;
          }
          chunks.push(r.value);
          received += r.value.length;
          ui.set(Math.min(received, known), known);
          return pump();
        });
      })();
    });
  }

  var started = Date.now();
  track('Started', navigator.platform || 'unknown');

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

        // Hand over the bytes already streamed, so nothing is fetched twice and
        // the content-hashed filenames are the only ones ever requested.
        instantiateWasm: function (imports, successCallback) {
          WebAssembly.instantiate(blobs.wasm, imports).then(function (out) {
            successCallback(out.instance, out.module);
          }).catch(function (e) { die('WebAssembly failed to start: ' + e, 'Instantiate failed'); });
          return {};
        },
        getPreloadedPackage: function () { return blobs.data; },

        onRuntimeInitialized: function () {
          sStart.done();
          track('Running', 'Seconds to start: ' + Math.round((Date.now() - started) / 1000));
          setTimeout(function () { boot.style.display = 'none'; }, 3500);
        },
        onAbort: function (what) { die('Bitcoin Core stopped: ' + what, 'Aborted'); }
      };

      var s = document.createElement('script');
      s.src = blobs.js;
      s.onerror = function () { die('Could not load ' + blobs.js, 'Glue script failed'); };
      document.body.appendChild(s);
    })
    .catch(function (e) { die('Download failed: ' + e.message, 'Download failed'); });
})();
