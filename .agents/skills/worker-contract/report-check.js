() => {
  // innerText covers rendered HTML, including closed details summaries, but not SVG text.
  const visible = el => el.getClientRects().length && getComputedStyle(el).visibility === 'visible';
  const svgText = [...document.querySelectorAll('svg text')]
    .filter(visible).map(el => el.textContent).join(' ');
  const words = (document.body.innerText + ' ' + svgText).trim().match(/\S+/g) || [];
  const graphics = [...document.querySelectorAll('svg, img, canvas')].filter(visible).length;
  return {visible_words: words.length, limit: 300, within_limit: words.length <= 300,
    visible_graphics_to_review: graphics};
}
