(() => {
  'use strict';
  const send = (value) => {
    if (window.AndroidChat && window.AndroidChat.postMessage) {
      window.AndroidChat.postMessage(JSON.stringify(value));
    }
  };
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.chat = { postMessage: send };
})();
