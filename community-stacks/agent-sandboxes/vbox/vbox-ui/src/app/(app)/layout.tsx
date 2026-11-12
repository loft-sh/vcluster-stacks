import { Footer, Sidebar } from "@/components/shell";
import { requireUser } from "@/lib/auth/session";

// Every page except /login. src/proxy.ts already redirects unauthenticated
// requests; this is the second check, at render time.
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  await requireUser();
  return (
    <div className="shell">
      <Sidebar />
      <div className="main">
        <main className="content">{children}</main>
        <Footer />
      </div>
    </div>
  );
}
