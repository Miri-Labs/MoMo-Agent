// Runs inside mountAvatar; state changes and their one-shot rest share its frame clock.
let requestedExpression = 'present', avatarExpression = 'present', faceTransition = null, faceRestAt = null;
let motionStartedAt = performance.now(), motionTransition = null;
const restMotion = () => ({ lift: 0, roll: 0, scaleX: 1, scaleY: 1 });
const hasAvatarMotion = () => ['thinking', 'working', 'speaking', 'concerned'].includes(avatarExpression);
const sampleAvatarMotion = time => {
  if (!playing) return null;
  const elapsed = Math.max(0, time - motionStartedAt), wave = period => Math.sin(elapsed / period * Math.PI * 2);
  const target = restMotion();
  if (avatarExpression === 'thinking') {
    target.roll = 5 * wave(2400); target.lift = 3 * wave(2400);
  } else if (avatarExpression === 'working') {
    target.scaleY = .95 + .04 * Math.cos(elapsed / 1200 * Math.PI * 2);
    target.scaleX = 1 + (1 - target.scaleY) * .6;
  } else if (avatarExpression === 'speaking') {
    target.lift = 5 * (1 - Math.cos(elapsed / 1100 * Math.PI * 2)) / 2;
    target.roll = 3 * wave(1800);
  } else if (avatarExpression === 'settled') {
    const phase = Math.min(elapsed / 1000, 1);
    target.lift = 20 * Math.sin(phase * Math.PI) ** 2;
    target.roll = 8 * Math.sin(phase * Math.PI * 2) * (1 - phase);
    target.scaleY = 1 - .12 * Math.sin(phase * Math.PI * 2);
    target.scaleX = 2 - target.scaleY;
  } else if (avatarExpression === 'concerned') {
    target.roll = 12 + 2 * wave(3200);
  }
  if (!motionTransition) return avatarExpression === 'present' ? null : target;
  const progress = clamp01((time - motionTransition.startedAt) / 320), t = progress * progress * (3 - 2 * progress);
  const result = Object.fromEntries(Object.entries(target).map(([key, value]) =>
    [key, motionTransition.from[key] + (value - motionTransition.from[key]) * t]));
  if (progress >= 1) motionTransition = null;
  return result;
};
const faceParameters = time => {
  const target = MOMO_EXPRESSIONS[avatarExpression];
  if (!faceTransition) return [target.left, target.right];
  const progress = clamp01((time - faceTransition.startedAt) / target.duration);
  if (progress >= 1) {
    faceTransition = null;
    return [target.left, target.right];
  }
  // A critically damped response gives MoMo a soft arrival without a comic overshoot.
  const t = (1 - (1 + 6 * progress) * Math.exp(-6 * progress)) / (1 - 7 * Math.exp(-6));
  return faceTransition.from.map((eye, side) => Object.fromEntries(Object.entries(eye).map(([key, value]) =>
    [key, value + ([target.left, target.right][side][key] - value) * t])));
};
const changeAvatarFace = (name, now) => {
  const from = faceParameters(now), fromMotion = sampleAvatarMotion(now) || restMotion();
  avatarExpression = name;
  motionStartedAt = now;
  motionTransition = playing ? { from: fromMotion, startedAt: now } : null;
  faceTransition = playing ? { from, startedAt: now } : null;
  faceRestAt = playing && MOMO_EXPRESSIONS[name].restAfter ? now + MOMO_EXPRESSIONS[name].restAfter : null;
};
const sampleAvatarFace = time => {
  if (playing && faceRestAt === null && MOMO_EXPRESSIONS[avatarExpression].restAfter) faceRestAt = time + MOMO_EXPRESSIONS[avatarExpression].restAfter;
  if (faceRestAt !== null && time >= faceRestAt) changeAvatarFace('present', time);
  const parameters = faceParameters(time);
  if (avatarExpression === 'present' && !faceTransition) return null;
  return parameters.map(momoEyeContour);
};
const setAvatarExpression = name => {
  if (destroyed) return;
  if (!Object.hasOwn(MOMO_EXPRESSIONS, name)) throw new Error('Unknown avatar expression: ' + name);
  if (requestedExpression === name) return;
  requestedExpression = name;
  const now = performance.now();
  changeAvatarFace(name, now);
  if (playing) requestTick();
  else render(now);
};
