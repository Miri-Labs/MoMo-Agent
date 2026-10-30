import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const bundle = fs.readFileSync(path.resolve(here, '../../Apps/iPhoneApp/Features/Assistant/Rendering/Web/vendor/momoagent-avatar.js'), 'utf8');
let time = 0, identifier = 0, headPaints = 0;
const scheduled = new Map();
function schedule(callback, delay) {
  const id = ++identifier;
  scheduled.set(id, { due:time + delay, callback });
  return id;
}
function advance(milliseconds) {
  const end = time + milliseconds;
  for (let count = 0; count < 10000; count++) {
    const next = [...scheduled].sort((a,b) => a[1].due - b[1].due)[0];
    if (!next || next[1].due > end) { time = end; return; }
    scheduled.delete(next[0]); time = next[1].due; next[1].callback(time);
  }
  throw new Error('Unexpected unbounded scheduler loop');
}
class Element {
  constructor(name) {
    this.name = name; this.attributes = {}; this.children = []; this.style = {}; this.dataset = {};
    this.classList = {
      add: value => { this.attributes.class = `${this.attributes.class || ''} ${value}`.trim(); },
      toggle: (value, enabled) => {
        const classes = new Set((this.attributes.class || '').split(' ').filter(Boolean));
        enabled ? classes.add(value) : classes.delete(value);
        this.attributes.class = [...classes].join(' ');
      },
    };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === 'd' && this.attributes.class === 'avatar-head') headPaints++;
  }
  removeAttribute(name) { delete this.attributes[name]; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  hasAttribute(name) { return Object.hasOwn(this.attributes, name); }
  querySelector(selector) {
    return descendants(this).slice(1).find(node => selector.startsWith('.')
      ? (node.attributes.class || '').split(' ').includes(selector.slice(1)) : node.name === selector);
  }
  get id() { return this.attributes.id; }
  set id(value) { this.attributes.id = value; }
  append(...children) { for (const child of children) { child.remove(); child.parent = this; this.children.push(child); } }
  appendChild(child) { this.append(child); return child; }
  replaceChildren(...children) { this.children.forEach(child => { child.parent = null; }); this.children = []; this.append(...children); }
  get lastElementChild() { return this.children.at(-1); }
  getContext() { return null; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = null; }
}
function descendants(element) { return [element,...element.children.flatMap(descendants)]; }
function find(element, attribute, value) { return descendants(element).find(node => node.attributes[attribute] === value); }
const context = vm.createContext({
  window:{}, document:{ createElement: name => new Element(name), createElementNS: (_,name) => new Element(name) },
  performance:{ now:() => time }, crypto:{ randomUUID:() => `avatar-${++identifier}` },
  setTimeout:schedule, clearTimeout:id => scheduled.delete(id),
  requestAnimationFrame:callback => schedule(callback,1000 / 60), cancelAnimationFrame:id => scheduled.delete(id)
});
vm.runInContext(bundle,context,{ filename:'momoagent-avatar.js' });
let passed = 0;
function test(name, operation) { operation(); passed++; console.log('PASS',name); }

const mount = new Element('span'), avatar = context.window.MoMoAvatar.create(mount);
const head = find(mount,'class','avatar-head');
test('static mount uses actual upstream geometry and schedules no work',() => {
  assert.ok(head.attributes.d.length > 100);
  assert.ok(descendants(mount).filter(node => node.attributes.d).every(node => !/NaN|Infinity/.test(node.attributes.d)));
  assert.equal(scheduled.size,0);
  assert.equal(mount.children[0].attributes['aria-hidden'],'true');
});
test('playing starts moving immediately and caps geometry at 30 paints per second',() => {
  const initial = head.attributes.d, count = headPaints;
  avatar.setActive(true); advance(200);
  assert.notEqual(head.attributes.d,initial,'Mount already shows the first pose; playback must not hold it again.');
  advance(800);
  assert.notEqual(head.attributes.d,initial);
  assert.ok(headPaints - count >= 28 && headPaints - count <= 30, `paint count: ${headPaints-count}`);
  const timers = [...scheduled.keys()]; avatar.setActive(true);
  assert.deepEqual([...scheduled.keys()],timers,'Repeated visible snapshots must not restart the animation.');
});
test('the upstream blink changes eye geometry during its real animation phase',() => {
  const eyes = find(mount,'class','avatar-eyes');
  const height = () => {
    const numbers = eyes.children[0].attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number);
    const ys = numbers.filter((_,index) => index % 2 === 1);
    return Math.max(...ys) - Math.min(...ys);
  };
  const openHeight = height(); advance(770);
  assert.ok(height() < openHeight * 0.8, `Blink height ${height()} vs ${openHeight}`);
});
test('hidden or reduced-motion stop cancels RAF and every step/blink timer',() => {
  avatar.setActive(false);
  const count = headPaints, shape = head.attributes.d;
  assert.equal(scheduled.size,0);
  advance(20000);
  assert.equal(headPaints,count); assert.equal(head.attributes.d,shape);
  assert.equal(mount.dataset.avatarActive,'false');
});
test('independent static icons use unique clip references without background work',() => {
  const other = new Element('span'), staticAvatar = context.window.MoMoAvatar.create(other,{ size:16 });
  const clips = [mount,other].map(element => descendants(element).find(node => node.name === 'clipPath').attributes.id);
  assert.notEqual(clips[0],clips[1]); assert.equal(scheduled.size,0);
  staticAvatar.destroy(); assert.equal(other.children.length,0);
});
test('destroy and immediate stop cannot leave callbacks or restart a destroyed instance',() => {
  avatar.setActive(true); assert.ok(scheduled.size > 0);
  avatar.setActive(false); assert.equal(scheduled.size,0);
  avatar.setActive(true); avatar.destroy(); assert.equal(scheduled.size,0);
  avatar.setActive(true); advance(10000);
  assert.equal(scheduled.size,0); assert.equal(mount.children.length,0);
});
test('thinking uses a distinct attentive pose and still owns all animation work',() => {
  const idleMount = new Element('span'), thinkingMount = new Element('span');
  const idle = context.window.MoMoAvatar.create(idleMount);
  const thinking = context.window.MoMoAvatar.create(thinkingMount,{ animation:'thinking' });
  assert.notEqual(find(idleMount,'class','avatar-head').attributes.d,find(thinkingMount,'class','avatar-head').attributes.d);
  const initial = find(thinkingMount,'class','avatar-head').attributes.d;
  thinking.setActive(true); advance(1400);
  assert.notEqual(find(thinkingMount,'class','avatar-head').attributes.d,initial);
  thinking.setActive(false); assert.equal(scheduled.size,0);
  idle.destroy(); thinking.destroy();
});
test('a full head turn moves the eyes visibly without a drifting body or held phases',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target,{size:84});
  const eyes = find(target,'class','avatar-eyes'), motion = eyes.parent;
  const eyeCenter = () => {
    const xs = eyes.children.flatMap(eye => eye.attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number).filter((_,index) => index%2===0));
    return (Math.min(...xs)+Math.max(...xs))/2;
  };
  const centers = [], shapes = [];
  actor.setActive(true);
  for(let i=0;i<156;i++) {
    advance(1000/30);
    centers.push(eyeCenter()); shapes.push(find(target,'class','avatar-head').attributes.d);
    assert.equal(motion.attributes.transform,'translate(0 0)','Head rotation must not add independent positional drift.');
  }
  assert.ok(Math.max(...centers)-Math.min(...centers)>22,'Turn must remain visible at the 84-point header size.');
  assert.ok(shapes.slice(0,60).every((shape,i,all) => i===0 || shape!==all[i-1]),'No idle hold may interrupt the turn.');
  actor.setActive(false); actor.destroy(); assert.equal(scheduled.size,0);
});
test('home adds a larger turn and a visible one-eye wink without a second motion clock',() => {
  function sample(animation) {
    const target = new Element('span'), actor = context.window.MoMoAvatar.create(target,{animation});
    const eyes = find(target,'class','avatar-eyes'), motion = eyes.parent;
    const centers = [], eyeRatios = [];
    actor.setActive(true);
    for(let i=0;i<150;i++) {
      advance(1000/30);
      const points = eyes.children.flatMap(eye => eye.attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number));
      const xs = points.filter((_,i) => i%2===0);
      centers.push((Math.min(...xs)+Math.max(...xs))/2);
      const heights = eyes.children.map(eye => {
        const ys = eye.attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number).filter((_, i) => i % 2);
        return Math.max(...ys) - Math.min(...ys);
      });
      eyeRatios.push(Math.max(...heights) / Math.min(...heights));
      assert.equal(motion.attributes.transform,'translate(0 0)');
      assert.ok(descendants(target).filter(node => node.attributes.d).every(node => !/NaN|Infinity/.test(node.attributes.d)));
    }
    actor.destroy(); assert.equal(scheduled.size,0);
    return {travel:Math.max(...centers)-Math.min(...centers), eyeRatios};
  }
  const quiet = sample('listening'), playful = sample('home');
  assert.ok(playful.travel > quiet.travel * 1.35, `Home eye travel ${playful.travel} vs header ${quiet.travel}`);
  assert.ok(Math.max(...playful.eyeRatios) > 2.8,'The home loop must visibly wink one eye, beyond a normal two-eye blink.');
});
test('switching between home and header keeps the same live geometry and scheduler',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  actor.setActive(true); advance(500);
  const svg = target.children[0], head = find(target,'class','avatar-head'), shape = head.attributes.d;
  actor.setAnimation('home');
  assert.equal(target.children[0],svg);
  assert.equal(head.attributes.d,shape,'Switching profiles must transition from the current on-screen pose.');
  const pending = [...scheduled.keys()]; actor.setAnimation('home');
  assert.deepEqual([...scheduled.keys()],pending);
  advance(100); assert.notEqual(head.attributes.d,shape);
  actor.setAnimation('listening'); advance(100);
  actor.setActive(false); assert.equal(scheduled.size,0);
  actor.setAnimation('home'); assert.equal(scheduled.size,0);
  actor.destroy();
});
test('low power halves geometry work without restarting the pose or creating a timer',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target,{animation:'home'});
  actor.setLowPower(true); actor.setActive(true);
  const before = headPaints; advance(1000);
  assert.ok(headPaints-before >= 14 && headPaints-before <= 15, `Low-power paints: ${headPaints-before}`);
  const pending = [...scheduled.keys()], shape = find(target,'class','avatar-head').attributes.d;
  actor.setLowPower(false);
  assert.deepEqual([...scheduled.keys()],pending);
  assert.equal(find(target,'class','avatar-head').attributes.d,shape);
  const normal = headPaints; advance(1000);
  assert.ok(headPaints-normal >= 28 && headPaints-normal <= 30);
  actor.setActive(false); actor.destroy(); assert.equal(scheduled.size,0);
});

test('all eight original scene expressions change only the eyes and render statically without scheduling',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  const head = find(target,'class','avatar-head'), original = head.attributes.d;
  const eyes = find(target,'class','avatar-eyes'), shapes = new Set();
  assert.equal(context.window.MoMoAvatar.expressions.length, 8);
  for (const expression of context.window.MoMoAvatar.expressions) {
    actor.setExpression(expression);
    shapes.add(eyes.children.map(eye => eye.attributes.d).join('|'));
    assert.equal(head.attributes.d, original, 'Expressions must preserve MoMo, including the body and its lobes.');
    assert.ok(eyes.children.every(eye => eye.attributes.d.length > 100 && !/NaN|Infinity/.test(eye.attributes.d)));
    assert.equal(target.dataset.avatarExpression, expression);
    assert.equal(scheduled.size, 0, 'A reduced-motion or hidden actor must not start a face animation.');
  }
  assert.equal(shapes.size, 8);
  assert.throws(() => actor.setExpression('toString'), /Unknown avatar expression/);
  actor.destroy();
});
test('eye shapes remain recognizably different at the actual 84-point header size',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  const metrics = name => {
    actor.setExpression(name);
    return find(target,'class','avatar-eyes').children.map(eye => {
      const coords = eye.attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number);
      const points = Array.from({length:coords.length/2},(_, i)=>coords.slice(i*2,i*2+2));
      const xs = points.map(point=>point[0]), ys = points.map(point=>point[1]);
      return {width:Math.max(...xs)-Math.min(...xs),height:Math.max(...ys)-Math.min(...ys),points};
    });
  };
  const present = metrics('present'), listening = metrics('listening'), thinking = metrics('thinking');
  const working = metrics('working'), settled = metrics('settled'), greeting = metrics('greeting');
  const scale = 126 / 450;
  assert.ok(listening[0].height * scale > 11, 'Listening must visibly open the eye at native header scale.');
  assert.ok(listening[0].height > present[0].height * 1.35);
  assert.ok(thinking[1].height > thinking[0].height * 1.8, 'Thinking needs one narrowed and one open eye.');
  assert.ok(working[0].width > present[0].width * 1.6 && working[0].height < present[0].height * .5);
  assert.ok(settled[0].width > present[0].width * 1.9);
  const arc = settled[0].points;
  assert.ok(Math.abs(arc[12][1] - (arc[8][1] + arc[16][1]) / 2) > 4, 'The smile must curve through its middle instead of looking like a straight bar.');
  assert.ok(greeting[1].height > greeting[0].height * 1.8, 'A greeting must read as a wink.');
  actor.destroy(); assert.equal(scheduled.size,0);
});
test('expressive body gestures share the capped clock, blend on interruption and clear when stopped',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  const motion = find(target,'class','avatar-eyes').parent;
  actor.setActive(true); actor.setExpression('working'); advance(400);
  const before = motion.attributes.transform;
  assert.match(before,/scale\(/);
  actor.setExpression('thinking'); assert.equal(motion.attributes.transform,before);
  advance(400); assert.notEqual(motion.attributes.transform,before);
  const normal = headPaints; advance(1000); assert.ok(headPaints-normal >=28 && headPaints-normal <=30);
  actor.setLowPower(true); const low = headPaints; advance(1000); assert.ok(headPaints-low >=14 && headPaints-low <=15);
  actor.setActive(false); assert.equal(motion.attributes.transform,'translate(0 0)');
  assert.equal(scheduled.size,0); actor.destroy();
});
test('expression transitions interrupt continuously and share the existing bounded frame clock',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  const eyes = find(target,'class','avatar-eyes'), shape = () => eyes.children[0].attributes.d;
  actor.setActive(true); advance(100);
  const initial = shape();
  actor.setExpression('greeting'); assert.equal(shape(), initial);
  const pending = [...scheduled.keys()]; actor.setExpression('greeting');
  assert.deepEqual([...scheduled.keys()], pending);
  advance(140); const mid = shape(); assert.notEqual(mid, initial);
  actor.setExpression('concerned'); assert.equal(shape(), mid);
  advance(400); assert.notEqual(shape(), mid);
  actor.setLowPower(true);
  const before = headPaints; actor.setExpression('listening'); advance(1000);
  assert.ok(headPaints - before >= 14 && headPaints - before <= 15);
  actor.setActive(false); assert.equal(scheduled.size, 0);
  const stopped = shape(); advance(10000); assert.equal(shape(), stopped);
  actor.setActive(true); actor.destroy();
  actor.setExpression('greeting'); advance(1000); assert.equal(scheduled.size, 0);
});
test('custom expression contours still follow the upstream blink',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  actor.setExpression('listening'); actor.setActive(true);
  const height = () => {
    const ys = find(target,'class','avatar-eyes').children[0].attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number).filter((_, i) => i % 2);
    return Math.max(...ys) - Math.min(...ys);
  };
  advance(1600); const open = height(); advance(170);
  assert.ok(height() < open * .8);
  actor.setActive(false); actor.destroy(); assert.equal(scheduled.size, 0);
});

test('finishing gives one soft acknowledgement and returns to an open attentive face',() => {
  const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
  const height = () => {
    const ys = find(target,'class','avatar-eyes').children[0].attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number).filter((_, i) => i % 2);
    return Math.max(...ys) - Math.min(...ys);
  };
  actor.setActive(true); actor.setExpression('settled'); advance(500);
  const smile = height();
  advance(1900); assert.ok(height() > smile * 1.6, 'A finished reply must not leave MoMo grinning indefinitely.');
  actor.setExpression('settled'); advance(400);
  assert.ok(height() > smile * 1.6, 'Repeated snapshots must not replay the acknowledgement.');
  actor.setActive(false); actor.destroy(); assert.equal(scheduled.size, 0);
});

test('every scene transition keeps both projected eye outlines free of self intersections',() => {
  const turn = (a, b, p) => (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
  const crosses = (a, b, c, d) => turn(a, b, c) * turn(a, b, d) < -1e-8 && turn(c, d, a) * turn(c, d, b) < -1e-8;
  for (const from of context.window.MoMoAvatar.expressions) for (const to of context.window.MoMoAvatar.expressions) {
    const target = new Element('span'), actor = context.window.MoMoAvatar.create(target);
    actor.setExpression(from); actor.setActive(true); actor.setExpression(to);
    for (let frame = 0; frame < 5; frame++) {
      advance(90);
      for (const eye of find(target,'class','avatar-eyes').children) {
        const coords = eye.attributes.d.match(/-?\d+(?:\.\d+)?/g).map(Number);
        const points = Array.from({ length: coords.length / 2 }, (_, i) => coords.slice(i * 2, i * 2 + 2));
        for (let i = 0; i < points.length; i++) for (let j = i + 2; j < points.length; j++) {
          if ((j + 1) % points.length !== i) assert.equal(crosses(points[i], points[(i + 1) % points.length], points[j], points[(j + 1) % points.length]), false, `${from} → ${to}, frame ${frame}`);
        }
      }
    }
    actor.destroy();
  }
  assert.equal(scheduled.size, 0);
});

test('the bundled page restores state after greetings and stops all work when hidden or reduced',() => {
  const target = new Element('div'), body = new Element('body'), listeners = new Map();
  const doc = {
    hidden: false, body, createElement: name => new Element(name), createElementNS: (_, name) => new Element(name),
    getElementById: () => target,
    querySelector: () => descendants(target).find(node => node.name === 'svg'),
    addEventListener: (name, callback) => listeners.set(name, callback),
  };
  const page = vm.createContext({
    window: { addEventListener: (name, callback) => listeners.set(name, callback) }, document: doc,
    performance: { now: () => time }, crypto: { randomUUID: () => `avatar-${++identifier}` },
    setTimeout: schedule, clearTimeout: id => scheduled.delete(id),
    requestAnimationFrame: callback => schedule(callback, 1000 / 60), cancelAnimationFrame: id => scheduled.delete(id),
  });
  vm.runInContext(bundle, page);
  page.MoMoAvatar = page.window.MoMoAvatar;
  const html = fs.readFileSync(path.resolve(here, '../../Apps/iPhoneApp/Features/Assistant/Rendering/Web/agent-avatar.html'), 'utf8');
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], page);
  const surface = page.window.agentAvatar, svg = target.children[0];
  const appearance = { active: true, reduceMotion: false, greeting: 0, expression: 'thinking', conversationID: 'current', playful: false, lowPower: false };
  surface.update({ ...appearance, expression: 'settled' }); advance(100);
  assert.equal(target.dataset.avatarExpression, 'present', 'Opening an existing completed reply must not replay a completion reaction.');
  surface.update(appearance); advance(500);
  assert.equal(target.dataset.avatarExpression, 'thinking');
  surface.update({ ...appearance, expression: 'settled', conversationID: 'history' });
  assert.equal(target.dataset.avatarExpression, 'present', 'Switching from an active chat to a completed history must not celebrate the other conversation.');
  surface.update(appearance); advance(500);
  surface.update({ ...appearance, greeting: 1 }); advance(150);
  assert.equal(target.dataset.avatarExpression, 'listening');
  surface.update({ ...appearance, greeting: 2 }); advance(1200);
  assert.equal(target.dataset.avatarExpression, 'thinking');
  assert.equal(target.children[0], svg);
  assert.equal(find(target, 'class', 'avatar-greeting').hasAttribute('transform'), false);
  surface.update({ ...appearance, greeting: 2, expression: 'settled' });
  assert.equal(target.dataset.avatarExpression, 'settled', 'Finishing an active response should acknowledge the result.');
  advance(2100);
  doc.hidden = true; listeners.get('visibilitychange')(); assert.equal(scheduled.size, 0);
  doc.hidden = false; listeners.get('visibilitychange')(); advance(100);
  for (const expression of page.MoMoAvatar.expressions) {
    surface.update({ ...appearance, greeting: 2, expression, reduceMotion: true });
    assert.equal(target.dataset.avatarExpression, expression);
    assert.equal(scheduled.size, 0);
  }
  surface.update({ ...appearance, greeting: 3, reduceMotion: true });
  assert.equal(target.dataset.avatarExpression, 'listening', 'A busy reduced-motion greeting acknowledges the user without interrupting the work.');
  assert.equal(scheduled.size, 0);
  surface.update({ ...appearance, greeting: 3, expression: 'concerned' }); advance(100);
  surface.update({ ...appearance, greeting: 3, expression: 'concerned', active: false });
  assert.equal(scheduled.size, 0);
  const paths = descendants(target).filter(node => node.attributes.d).map(node => node.attributes.d);
  advance(10000);
  assert.deepEqual(descendants(target).filter(node => node.attributes.d).map(node => node.attributes.d), paths);
  listeners.get('pagehide')(); assert.equal(target.children.length, 0); assert.equal(scheduled.size, 0);
});
console.log(`${passed} avatar runtime tests passed`);
