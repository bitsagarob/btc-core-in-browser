// The demo ships one fixed regtest chain, baked into the page. Bitcoin Core's
// window decides it is out of sync whenever the tip is more than 90 minutes old
// and covers itself with a modal warning about incorrect balances, which for a
// chain that will never gain another block means always.
//
// Rather than patch Core, shift the clock the module sees so that "now" sits
// just after the last block. The offset is constant, so time still advances
// normally inside the tab. Emscripten's time() and gettimeofday() both read
// Date.now(), and this file is linked with --pre-js so it applies in the pthread
// workers too, which is where Core's own threads actually run.
(function () {
  var TIP_MS = Date.parse('2026-09-17T13:22:31Z');
  var target = TIP_MS + 120000;
  var real = Date.now.bind(Date);
  var offset = real() - target;
  if (offset <= 0) return;
  Date.now = function () { return real() - offset; };
})();
