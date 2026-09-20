(() => {
  const gallery = document.querySelector('.hero-gallery');
  if (!gallery) return;
  const viewport = gallery.querySelector('.hero-gallery-viewport');
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  let paused = reducedMotion.matches;
  let hovering = false;
  let focused = false;
  let visible = false;
  let frame;
  let previous;
  let offset = viewport.scrollLeft;
  function tick(time) {
    const distance = viewport.scrollWidth - viewport.clientWidth;
    if (previous !== undefined && distance > 0) {
      offset = Math.min(offset + Math.min(time - previous, 50) * 0.035, distance);
      viewport.scrollLeft = offset;
    }
    if (offset >= distance) return;
    previous = time;
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame);
    previous = undefined;
    offset = viewport.scrollLeft;
    if (!paused && !hovering && !focused && visible && !document.hidden) frame = requestAnimationFrame(tick);
  }
  viewport.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') { hovering = true; sync(); } });
  viewport.addEventListener('pointerleave', () => { hovering = false; sync(); });
  viewport.addEventListener('focusin', () => { focused = true; sync(); });
  viewport.addEventListener('focusout', event => { focused = viewport.contains(event.relatedTarget); sync(); });
  function pauseForInteraction() { paused = true; sync(); }
  viewport.addEventListener('pointerdown', pauseForInteraction);
  viewport.addEventListener('wheel', pauseForInteraction, { passive: true });
  reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; sync(); });
  document.addEventListener('visibilitychange', sync);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); }).observe(gallery);
})();
