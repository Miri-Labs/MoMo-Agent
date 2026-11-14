// Older Android System WebViews can load the shared renderer before receiving
// the corresponding Chromium DOM and ECMAScript updates.
(() => {
  if (!Element.prototype.replaceChildren) {
    Object.defineProperty(Element.prototype, 'replaceChildren', {
      configurable: true, writable: true,
      value(...nodes) {
        const content = document.createDocumentFragment();
        content.append(...nodes);
        this.textContent = '';
        this.appendChild(content);
      },
    });
  }
  if (!Array.prototype.at) {
    Object.defineProperty(Array.prototype, 'at', {
      configurable: true, writable: true,
      value(index) {
        const offset = Math.trunc(Number(index)) || 0;
        return this[offset < 0 ? this.length + offset : offset];
      },
    });
  }
  if (!Object.hasOwn) {
    Object.defineProperty(Object, 'hasOwn', {
      configurable: true, writable: true,
      value: (object, key) => Object.prototype.hasOwnProperty.call(object, key),
    });
  }
})();
