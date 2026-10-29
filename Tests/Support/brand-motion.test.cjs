const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
let scheduled = new Map(), next = 0, image, intersection, draws = [];
const mark = { dataset:{}, querySelector:() => ({ getContext:() => ({
  fillRect:() => {}, drawImage:(_,x,y,width) => draws.push(width)
}) }) };
const context = vm.createContext({
  window:{}, document:{hidden:false}, console,
  Image:class { constructor() { image = this; } },
  IntersectionObserver:class { constructor(callback) { intersection = callback; } observe() {} },
  requestAnimationFrame:callback => { const id = ++next; scheduled.set(id,callback); return id; },
  cancelAnimationFrame:id => scheduled.delete(id)
});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../Apps/iPhoneApp/Features/Assistant/Rendering/Web/brand-motion.js'),'utf8'),context);
const edge = frame => 56 * (1 + 0.035 * (1 - Math.cos(frame / 174 * Math.PI * 2)) / 2);
const motion = context.window.MoMoCreateBrandMotion(mark);
const tick = now => {
  assert.equal(scheduled.size,1,'Only one animation loop may run');
  const [id,callback] = [...scheduled][0]; scheduled.delete(id); callback(now);
};
motion.update(true,true);
assert.equal(image.src,undefined,'Reduced motion uses only the small still image');
motion.update(true,false);
assert.equal(image.src,'brand-thinking.png','Use the approved product icon, not the legacy W atlas');
assert.equal(scheduled.size,0,'First paint and streaming do not wait for artwork decoding');
assert.equal(mark.dataset.motionReady,undefined);
image.naturalWidth=1024;image.naturalHeight=1024;image.onload();
assert.equal(mark.dataset.motionReady,'true');
tick(0);tick(1000);
assert.equal(draws.at(-1),edge(30));
const drawCount = draws.length;tick(1001);assert.equal(draws.length,drawCount,'Do not redraw an unchanged frame on faster displays');
motion.update(true,false);tick(2000);
assert.equal(draws.at(-1),edge(60),'Activity snapshots and phase changes do not reset the clock');
tick(5800);assert.equal(draws.at(-1),edge(0),'The 5.8 second loop wraps without a duplicate hold frame');
tick(5900);const beforePause = draws.at(-1);
intersection([{isIntersecting:false}]);assert.equal(scheduled.size,0);
intersection([{isIntersecting:true}]);tick(9000);
assert.equal(draws.at(-1),beforePause,'Offscreen time is paused');
context.document.hidden=true;motion.update(true,false);assert.equal(scheduled.size,0);
context.document.hidden=false;motion.update(true,false);tick(11000);
assert.equal(draws.at(-1),beforePause,'Background time is paused');
motion.update(true,true);assert.equal(scheduled.size,0);assert.equal(draws.at(-1),edge(0));
motion.update(true,false);tick(12000);tick(12500);
motion.suspend();assert.equal(scheduled.size,0);
motion.update(true,false);assert.equal(scheduled.size,0,'Native teardown cannot restart the animation');
motion.resume();tick(15000);
motion.update(false,false);assert.equal(scheduled.size,0);assert.equal(draws.at(-1),edge(0));
motion.update(true,false);tick(16000);tick(16100);assert.equal(draws.at(-1),edge(3));
console.log('PASS approved brand artwork timing, phase continuity, visibility, reduced motion and native teardown');
