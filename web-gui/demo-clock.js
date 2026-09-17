// Shift the clock the module sees to just after the baked chain's last block.
//
// Bitcoin Core's window calls itself out of sync whenever the tip is more than
// 90 minutes old and covers itself with a warning about incorrect balances,
// which for a chain that will never gain another block means always. -maxtipage
// does not help: that governs the node's view of initial block download, the
// modal is driven by the GUI's own constant. Linked with --pre-js so it also
// applies in the pthread workers, where Core's own threads run.
//
// make-regtest-chain.sh rewrites TIP_MS when it mines a new chain.
(function () {
  var TIP_MS = Date.parse('2026-09-17T19:29:23Z');
  var real = Date.now.bind(Date);
  // Quantised so that a thread starting ten minutes in does not report a clock
  // ten minutes behind the one that started first.
  var offset = Math.floor((real() - (TIP_MS + 120000)) / 60000) * 60000;
  // A malformed TIP_MS gives NaN, and NaN <= 0 is false, so an unguarded
  // comparison would hand every thread a clock that reads NaN.
  if (!(offset > 0)) return;
  Date.now = function () { return real() - offset; };
})();
