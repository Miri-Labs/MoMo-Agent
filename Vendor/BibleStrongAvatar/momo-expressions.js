// Original MoMo geometry, in the character's existing 17 × 29 eye coordinate space.
const momoEye = (changes = {}) => ({ width: 17, height: 29, bend: 0, tilt: 0, x: 0, y: 0, ...changes });
const MOMO_EXPRESSIONS = Object.freeze({
  present: { left: momoEye(), right: momoEye(), duration: 420 },
  listening: {
    left: momoEye({ width: 25, height: 42, tilt: -7, x: 1, y: -4 }),
    right: momoEye({ width: 23, height: 36, tilt: 6, x: 1, y: -2 }), duration: 280,
  },
  thinking: {
    left: momoEye({ width: 28, height: 10, tilt: -14, x: 6, y: -6 }),
    right: momoEye({ width: 22, height: 30, tilt: 9, x: 6, y: -7 }), duration: 300,
  },
  working: {
    left: momoEye({ width: 32, height: 11, tilt: 5, x: -2, y: 3 }),
    right: momoEye({ width: 32, height: 11, tilt: -5, x: 2, y: 3 }), duration: 220,
  },
  speaking: {
    left: momoEye({ width: 26, height: 30, bend: -2, tilt: -5, x: -1 }),
    right: momoEye({ width: 29, height: 25, bend: -2, tilt: 5, x: 1 }), duration: 260,
  },
  settled: {
    left: momoEye({ width: 38, height: 9, bend: -10, tilt: -4, y: -1 }),
    right: momoEye({ width: 38, height: 9, bend: -10, tilt: 4, y: -1 }), duration: 240, restAfter: 1700,
  },
  concerned: {
    left: momoEye({ width: 28, height: 32, tilt: 15, x: -3, y: 2 }),
    right: momoEye({ width: 26, height: 15, tilt: -15, x: 3, y: -3 }), duration: 380,
  },
  greeting: {
    left: momoEye({ width: 36, height: 8, bend: -9, tilt: -8, y: -1 }),
    right: momoEye({ width: 27, height: 37, tilt: 8, x: 1, y: -2 }), duration: 220,
  },
});

function momoEyeContour(eye) {
  const halfWidth = eye.width / 2, halfHeight = eye.height / 2, radius = Math.min(halfWidth, halfHeight);
  const angle = eye.tilt * Math.PI / 180, c = Math.cos(angle), s = Math.sin(angle);
  return Array.from({ length: 64 }, (_, i) => {
    // Sample the straight edges too, so bending creates an actual arc at small display sizes.
    const segment = Math.floor(i / 8), t = (i % 8) / 8, insetX = halfWidth - radius, insetY = halfHeight - radius;
    let x, y;
    if (segment % 2 === 0) {
      const corner = segment / 2, theta = (corner + t) * Math.PI / 2;
      x = (corner === 0 || corner === 3 ? insetX : -insetX) + radius * Math.cos(theta);
      y = (corner < 2 ? insetY : -insetY) + radius * Math.sin(theta);
    } else if (segment === 1) { x = insetX * (1 - 2 * t); y = halfHeight; }
    else if (segment === 3) { x = -halfWidth; y = insetY * (1 - 2 * t); }
    else if (segment === 5) { x = insetX * (2 * t - 1); y = -halfHeight; }
    else { x = halfWidth; y = insetY * (2 * t - 1); }
    y += eye.bend * (1 - (x / halfWidth) ** 2);
    return [eye.x + x * c - y * s, eye.y + x * s + y * c];
  });
}
