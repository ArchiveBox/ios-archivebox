(() => {
  const gallery = document.querySelector('.hero-gallery');
  if (!gallery) return;
  const viewport = gallery.querySelector('.hero-gallery-viewport');
  const group = gallery.querySelector('.hero-gallery-group');
  const toggle = gallery.querySelector('.hero-gallery-toggle');
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const track = gallery.querySelector('.hero-gallery-track');
  new ResizeObserver(() => {
    const distance = group.getBoundingClientRect().width + 24;
    const copies = Math.ceil(viewport.clientWidth / distance);
    while (track.children.length > copies + 1) track.lastElementChild.remove();
    while (track.children.length < copies + 1) {
      const copy = group.cloneNode(true);
      copy.setAttribute('aria-hidden', 'true');
      copy.querySelectorAll('a').forEach(link => { link.tabIndex = -1; });
      track.append(copy);
    }
  }).observe(viewport);
  let paused = reducedMotion.matches;
  let hovering = false;
  let focused = false;
  let visible = false;
  let frame;
  let previous;
  let offset = viewport.scrollLeft;
  function updateButton() {
    toggle.textContent = paused ? 'Play gallery' : 'Pause gallery';
    toggle.setAttribute('aria-pressed', String(paused));
  }
  function tick(time) {
    const distance = group.getBoundingClientRect().width + 24;
    if (previous !== undefined && distance > 0) {
      offset = (offset + Math.min(time - previous, 50) * 0.035) % distance;
      viewport.scrollLeft = offset;
    }
    previous = time;
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame);
    previous = undefined;
    offset = viewport.scrollLeft;
    if (!paused && !hovering && !focused && visible && !document.hidden) frame = requestAnimationFrame(tick);
  }
  toggle.hidden = false;
  updateButton();
  toggle.addEventListener('click', () => { paused = !paused; updateButton(); sync(); });
  viewport.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') { hovering = true; sync(); } });
  viewport.addEventListener('pointerleave', () => { hovering = false; sync(); });
  viewport.addEventListener('focusin', () => { focused = true; sync(); });
  viewport.addEventListener('focusout', event => { focused = viewport.contains(event.relatedTarget); sync(); });
  function pauseForInteraction() { paused = true; updateButton(); sync(); }
  viewport.addEventListener('pointerdown', pauseForInteraction);
  viewport.addEventListener('wheel', pauseForInteraction, { passive: true });
  reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; updateButton(); sync(); });
  document.addEventListener('visibilitychange', sync);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); }).observe(gallery);
})();
