() => {
  // innerText covers rendered HTML, including closed details summaries, but not SVG text.
  const visible = el => el.getClientRects().length && getComputedStyle(el).visibility === 'visible';
  const svgText = [...document.querySelectorAll('svg text')]
    .filter(visible).map(el => el.textContent).join(' ');
  const text = document.body.innerText + ' ' + svgText;
  const words = text.trim().match(/\S+/g) || [];
  const graphics = [...document.querySelectorAll('svg, img, canvas')].filter(visible).length;
  // The "En 1 minuto" block: three answers, the last one a decision or "nada, solo informativo".
  const cards = [...document.querySelectorAll('#en-1-minuto .card')].filter(c => c.innerText.trim().split(/\s+/).length > 3);
  const last = cards[2];
  const asks = !!last && (/nada,? solo informativo/i.test(last.innerText) || !!last.querySelector('a[href], button, form'));
  // Opaque identifiers in visible text: hashes with a digit, paths, and task ids ending in a date stamp.
  const opaque = (text.match(/\b(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b|(?:^|\s)\/?[\w.-]+\/[\w./-]+\.\w+|[a-z][a-z0-9-]*-20\d{6}\b/gi) || []).map(s => s.trim());
  const analogies = text.match(/\b(es como si|como si fuera|imagina que|piensa en .{0,30} como)\b/gi) || [];
  return {visible_words: words.length, limit: 300, within_limit: words.length <= 300,
    one_minute_block: cards.length >= 3, third_answer_is_decision_or_informative: asks,
    opaque_identifiers_visible: opaque, possible_analogies: analogies,
    visible_graphics_to_review: graphics};
}
