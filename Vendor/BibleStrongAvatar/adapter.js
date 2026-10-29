// MoMoAgent adapter. Shapes, projection, ambient motion, transitions and blink are upstream code.
function createMoMoAgentAvatar(target, { size = 28, animation = 'listening' } = {}) {
  const motion = { size, animation, autoplay: false, maxFrameRate: 30 };
  const controller = mountAvatar(target, motion);
  const svg = controller.element;
  svg.classList.add('life-avatar');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.removeAttribute('role');
  svg.removeAttribute('aria-label');
  let active = false, destroyed = false;
  target.dataset.avatarActive = 'false';
  return {
    setExpression(value) {
      if (destroyed) return;
      controller.setExpression(value);
      target.dataset.avatarExpression = value;
    },
    setAnimation(value) {
      if (destroyed || animation === value) return;
      animation = value;
      if (active) controller.play(animation);
    },
    setLowPower(value) { motion.maxFrameRate = value ? 15 : 30; },
    setActive(value) {
      if (destroyed || active === value) return;
      active = value;
      target.dataset.avatarActive = String(active);
      if (active) controller.play(animation);
      else controller.stop();
    },
    destroy() {
      if (destroyed) return;
      destroyed = true;
      active = false;
      target.dataset.avatarActive = 'false';
      controller.destroy();
    }
  };
}
window.MoMoAvatar = Object.freeze({ create: createMoMoAgentAvatar, expressions: Object.freeze(Object.keys(MOMO_EXPRESSIONS)) });
