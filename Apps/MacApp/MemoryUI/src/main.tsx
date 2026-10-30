import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { StarMap } from '../../../../Vendor/HermesAgent/apps/desktop/src/app/starmap/star-map';
import { memoryGraph, memoryID } from './adapter.mjs';
import { isEn } from './preview.mjs';

let graph = memoryGraph([]);
export function inspectNode(nodeID: string) {
  const id = memoryID(nodeID, graph);
  if (id) window.webkit?.messageHandlers.memory.postMessage({ action: 'inspect', id });
}
function App() {
  const [current, setCurrent] = useState(graph);
  window.setMemories = (memories, dark) => {
    graph = memoryGraph(memories);
    document.documentElement.classList.toggle('dark', dark);
    setCurrent(graph);
  };
  useEffect(() => { window.webkit?.messageHandlers.memory.postMessage({ action: 'ready' }); }, []);
  return current.nodes.length ? <StarMap graph={current} /> : <p className="empty">{isEn() ? 'No organized memories yet' : '还没有整理好的记忆'}</p>;
}
createRoot(document.getElementById('root')!).render(<App />);
