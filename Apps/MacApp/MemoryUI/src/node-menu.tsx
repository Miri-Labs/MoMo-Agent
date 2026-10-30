import { useEffect } from 'react';
import { inspectNode } from './main';

export function NodeContextMenu({ target, onClose }) {
  useEffect(() => {
    if (target) { inspectNode(target.id); onClose(); }
  }, [target]);
  return null;
}
