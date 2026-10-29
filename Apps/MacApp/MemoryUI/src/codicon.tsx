export function Codicon({ name, size }) {
  return <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    {name === 'debug-pause' ? <path d="M3 2h3v12H3zm7 0h3v12h-3z"/> : <path d="M4 2l10 6-10 6z"/>}
  </svg>;
}
