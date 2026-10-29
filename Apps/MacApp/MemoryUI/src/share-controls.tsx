import { isEn } from './preview.mjs';

export function ShareControls() {
  return <span className="starmap-help text-xs text-muted-foreground">{isEn() ? 'Click to read · Drag to pan · Double-click to reset' : '点击阅读 · 拖动平移 · 双击复位'}</span>;
}
