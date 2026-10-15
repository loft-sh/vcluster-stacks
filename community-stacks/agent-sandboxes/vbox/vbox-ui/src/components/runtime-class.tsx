import { Cpu } from "lucide-react";

// vNode's mark, from the official horizontal logo on vnode.com (the symbol only,
// cropped to its own bounds; the wordmark is written as text beside it).
export function VNodeMark({ size = 16 }: { size?: number }) {
  return (
    <svg
      className="vnode-mark"
      width={size}
      height={size}
      viewBox="0 0.86 19.67 22.25"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden
    >
      <path
        d="M19.6701 0.861816H9.72942C9.72942 3.61727 11.9605 5.84283 14.7063 5.84283V10.5986L4.99012 0.861816H4.97692H0V11.1948C0 12.5195 0.528056 13.7913 1.46535 14.7318L4.97692 18.2424L9.83503 23.1042C11.7756 21.1568 11.7756 18.0039 9.83503 16.0566L4.97692 11.1815V7.88293L14.7063 17.6463L15.01 17.9509L18.2179 14.7318L18.5083 14.4404H18.4951C19.2476 13.5263 19.6701 12.387 19.6701 11.208V0.861816Z"
        fill="#0C00FF"
      />
    </svg>
  );
}

// The RuntimeClass "vnode" is vNode's: shown with its logo and its product name.
export const isVNode = (name?: string) => name?.toLowerCase() === "vnode";

// A runtime class name with its icon. vNode gets its logo and spelling; any other
// runtime class is shown as named. `icon` controls whether an icon is drawn for a
// non-vNode class (the key-value rows have none).
export function RuntimeClass({
  name,
  fallback,
  size = 16,
  icon = true,
}: {
  name?: string;
  fallback: string;
  size?: number;
  icon?: boolean;
}) {
  if (isVNode(name)) {
    return (
      <span className="with-icon" title="RuntimeClass vnode">
        <VNodeMark size={size} />
        vNode
      </span>
    );
  }
  if (!icon) return <>{name ?? fallback}</>;
  return (
    <span className="with-icon">
      <Cpu size={size} strokeWidth={1.75} />
      {name ?? fallback}
    </span>
  );
}
