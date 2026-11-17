// The vBox mark: an isometric box whose lid is lifted off, so the gap between lid
// and body reads as a "v". The three faces are the brand oranges (hover, primary,
// pressed) for the lit top, the front and the shaded side. src/app/icon.svg is the
// same drawing, as the browser tab icon.
export function VBoxMark({ size = 30, className }: { size?: number; className?: string }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 32 32"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden
    >
      <g strokeLinejoin="round" strokeWidth={1.5}>
        <path d="M16 1 28 8 16 15 4 8Z" fill="#FF8433" stroke="#FF8433" />
        <path d="M4 13 16 20V31L4 24Z" fill="#FF6600" stroke="#FF6600" />
        <path d="M16 20 28 13V24L16 31Z" fill="#CC5100" stroke="#CC5100" />
      </g>
    </svg>
  );
}

export function VBoxLogo({ size = 30 }: { size?: number }) {
  return (
    <span className="logo-lockup">
      <VBoxMark size={size} className="logo-mark" />
      <span className="logo-word">vBox</span>
    </span>
  );
}
