(() => {
  'use strict';
  // Animate the approved product artwork, including reduced-motion and offscreen states.
  window.MoMoCreateBrandMotion = mark => {
    const canvas = mark.querySelector('canvas'), context = canvas.getContext('2d', { alpha:false });
    const artwork = new Image();
    const width = 64, height = 56, count = 174, fps = 30;
    let active = false, reduced = false, visible = true, suspended = false, loaded = false, requested = false;
    let frame = null, previous = null, elapsed = 0, painted = -1;
    function draw(index) {
      if (!loaded || index === painted) return;
      const scale = 1 + 0.035 * (1 - Math.cos(index / count * Math.PI * 2)) / 2;
      const edge = height * scale;
      context.fillStyle = '#000'; context.fillRect(0, 0, width, height);
      context.drawImage(artwork, (width - edge) / 2, (height - edge) / 2, edge, edge);
      painted = index;
    }
    function tick(now) {
      frame = null;
      if (previous !== null) elapsed += (now - previous) / 1000;
      previous = now;
      draw(Math.floor(elapsed * fps) % count);
      frame = requestAnimationFrame(tick);
    }
    function sync() {
      const running = loaded && active && !reduced && visible && !suspended && !document.hidden;
      const state = running ? 'running' : 'paused';
      if (mark.dataset.motionState !== state) mark.dataset.motionState = state;
      if (running && frame === null) frame = requestAnimationFrame(tick);
      if (!running) {
        if (frame !== null) cancelAnimationFrame(frame);
        frame = null; previous = null;
        if (reduced || !active) { elapsed = 0; draw(0); }
      }
    }
    artwork.onload = () => {
      if (!artwork.naturalWidth || artwork.naturalWidth !== artwork.naturalHeight) {
        console.error('Brand artwork must be square.');
        return;
      }
      loaded = true; draw(0); mark.dataset.motionReady = 'true'; sync();
    };
    artwork.onerror = () => console.error('Could not load the bundled brand artwork.');
    new IntersectionObserver(entries => {
      visible = entries[0].isIntersecting; sync();
    }).observe(mark);
    return {
      update(isActive, reduceMotion) {
        active = isActive; reduced = reduceMotion;
        if (active && !reduced && !requested) { requested = true; artwork.src = 'brand-thinking.png'; }
        sync();
      },
      suspend() { suspended = true; sync(); },
      resume() { suspended = false; sync(); }
    };
  };
})();
