import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Emits .next/standalone: a self-contained server.js plus only the node_modules
  // it needs, which is what the Dockerfile copies into the runtime image.
  output: "standalone",
  poweredByHeader: false,
  // Loaded with Node's require at runtime rather than bundled: the client reads
  // kubeconfig files and spawns exec credential plugins.
  // undici too: the log stream hands client-node's undici dispatcher to undici's
  // fetch, and both must be the same copy of the library.
  serverExternalPackages: ["@kubernetes/client-node", "undici"],
};

export default nextConfig;
