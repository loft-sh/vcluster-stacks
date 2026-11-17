# vbox-ui

Web UI for [Kubernetes Agent Sandbox](https://agent-sandbox.sigs.k8s.io/docs/):
shows the available and claimed sandboxes in a tenant cluster, with their claims,
warm pools and templates. Next.js (App Router, TypeScript), styled after vCluster
Platform, reading straight from the Kubernetes API server. Read-only: it never
writes to the cluster. Sign-in is optional, through any OpenID Connect provider.

## Pages

| Page | Shows |
| --- | --- |
| Sandboxes | Every `Sandbox`, whether it is **available** (still owned by its `SandboxWarmPool`) or **claimed** (ownership moved to a `SandboxClaim`), plus health, claim, template, runtime class, limits, pod IP and node. Also lists pods whose sandbox is already deleted. |
| Claims | Every `SandboxClaim`: ready state, assigned sandbox, warm or cold start, creator, shutdown time. |
| Warm Pools | Ready / desired per pool, and how many of its sandboxes are available or claimed. |
| Templates | Image, runtime class, limits, network policy mode, claim override policies, pools using it. |
| Settings | The OpenID Connect provider vBox signs users in with. See [Sign-in](#sign-in-openid-connect). |

Every name opens a detail page with **Details** (cards) and **Config** (the raw
objects as YAML).

Pages re-render on the server every 5 seconds (the **Auto-refresh** toggle).

## Audit

**Audit** lists one session per claimed sandbox, showing which client used which
sandbox:

| Column | Shows |
| --- | --- |
| Client | The claim's `agents.x-k8s.io/created-by` label, or the HTTP user agent when no claim was observed, plus the user agent and client IP |
| Sandbox | The sandbox and its namespace. Opens the session's timeline |
| Claim | The `SandboxClaim`, its warm pool and whether it started warm or cold |
| Created | When the session started (the claim's creation time) |
| Session Duration | Start to release, or start to now while the session is active |
| Steps | Client requests through the Sandbox Router, plus how many failed |

Sessions can be filtered by client and namespace, and sorted by any column except
Sandbox and Claim. A session's timeline lists its steps and lifecycle events and can
be exported as JSON Lines.

A collector inside the vBox server records them. It starts with the server
(`src/instrumentation.ts`), and `VBOX_COLLECTOR=off` disables it. It reads two
sources:

| Source | What it records |
| --- | --- |
| `SandboxClaim` objects, polled every 3 s | claim created, sandbox assigned (warm or cold), ready, release requested, released |
| Sandbox Router access log, followed live | one **step** per client request: method, path, status, duration, client IP, user agent, bytes returned |

The router outlives the sandboxes, so the collector also recovers sessions that
ended before it was running, from the router's log history. Those have no claim
attached, so their client is the HTTP user agent. They end at their last recorded
activity once their sandbox is gone.

Request and response payloads and the sandbox pods' own logs are not recorded.
Databases written by earlier versions still hold such events; they stay in the hash
chain and are verified, but are not shown.

### Storage and integrity

The trail is a SQLite database at `$VBOX_DATA_DIR/audit.db` (default `./data`),
using Node's built-in `node:sqlite`.

- **Append-only:** triggers reject `UPDATE` and `DELETE` on the events table.
- **Hash-chained:** every event stores the SHA-256 of the previous event. The
  session timeline re-verifies the whole chain on every load, and an edit made
  behind the triggers' back shows up as "chain broken at event N".
- **Restart-safe:** each log source has a saved read position, and every event has
  a unique key, so a restarted collector resumes without gaps or duplicates.

One collector should write to a database. Run a single replica.

## Sign-in (OpenID Connect)

Sign-in is off until a provider is configured: vBox is then open to anyone who can
reach it, as before. **Settings** configures the provider. With **Require sign-in**
on, every page redirects to `/login`, which offers one **Sign in with ...** button.

**Settings fields:**

| Field | Notes |
| --- | --- |
| Issuer URL | vBox reads `/.well-known/openid-configuration` under it. Entra ID: `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Client ID, client secret | A blank secret makes vBox a public client. The secret is never sent back to the browser; blank on save keeps the stored one |
| Scopes | Default `openid profile email`. `openid` is always added |
| Username claim | Default `email`, then `preferred_username`, `email`, `sub` |
| Groups claim, allowed groups | With allowed groups set, only members of at least one may sign in. Entra ID sends group object IDs |
| Provider sign-out | Also ends the session at the provider (RP-initiated logout) |

**Test connection** fetches the discovery document without saving. Saving runs the
same check, so a provider that cannot be reached is never saved as enabled.

**Register two URIs with the provider.** Both are shown on the page, ready to copy:

- **Redirect URI:** `<vBox URL>/api/auth/callback`
- **Post-logout redirect URI:** `<vBox URL>/login?signedOut=1`, only needed with
  provider sign-out

The vBox URL comes from `VBOX_PUBLIC_URL` when set, otherwise from the request's
`X-Forwarded-Proto`/`X-Forwarded-Host` (or `Host`). Set `VBOX_PUBLIC_URL` in
production.

**The flow:**

- **Authorization code flow** with PKCE (S256), `state` and `nonce`, using
  [`openid-client`](https://github.com/panva/openid-client). The ID token is
  validated against the provider's keys. Userinfo fills in claims the ID token
  leaves out.
- **Login binding:** the `state` is also bound to the browser in a short-lived
  cookie, so a callback URL started elsewhere or used twice is rejected.
- **Sessions:** server-side, 8 hours, behind an `HttpOnly`, `SameSite=Lax` cookie,
  `Secure` over https. Only the token's SHA-256 is stored.
- **Provider changes:** a session is tied to the issuer and client ID it was issued
  under, so changing either signs everyone out.
- **Sign-out:** a POST from the sidebar.
- **Enforcement:** `src/proxy.ts` redirects pages to `/login` and answers API calls
  with 401. Pages, the Settings action and the export route check the session
  again themselves. `/api/healthz` stays open for probes.

**Authorization:** any signed-in user can use every page, Settings included.
Restrict who can sign in with allowed groups.

**Where the settings live.** In a cluster, the settings are the Secret in vBox's
own namespace annotated `vbox.vcluster.com/oidc-config: "true"`. vBox finds it by
that annotation, not by name. `VBOX_OIDC_SECRET_NAMESPACE` overrides the
namespace (default: the pod's own) and `VBOX_OIDC_SECRET_ANNOTATION` the key.
Exactly one Secret there may carry the annotation. The Secret is the source of
truth:

- **Reading:** vBox re-reads it at most every 5 seconds. A change made with
  `kubectl edit secret` or by External Secrets shows up in the UI that quickly.
- **Saving:** the Settings page writes it back with the `resourceVersion` the page
  was loaded with. A change made to the Secret in between is refused with a
  message, never silently overwritten. Keys vBox does not know are kept. The
  `vbox.vcluster.com/updated-at` and `updated-by` annotations record the last save
  from the UI.
- **Format:** one key per field, as plain strings: `enabled`, `displayName`,
  `issuerUrl`, `clientId`, `clientSecret`, `scopes`, `usernameClaim`,
  `groupsClaim`, `allowedGroups` (one per line) and `providerLogout`.
- **No usable Secret:** sign-in fails closed. If vBox starts and cannot settle on
  the settings (no Secret annotated, more than one, or Secrets cannot be listed),
  every page leads to the sign-in page, which names the problem, and the API
  answers 503. If it becomes unreadable later, the last settings read stay in
  force and the Settings page shows a warning.

Outside a cluster (local development, no `VBOX_OIDC_SECRET_NAMESPACE`), the
settings live in `$VBOX_DATA_DIR/auth.db`.

**Sessions** always live in `$VBOX_DATA_DIR/auth.db`, beside the audit trail but in
their own database, because they change and the audit trail is append-only.

**Locked out?** Start vBox with `VBOX_AUTH=off` (the chart's `disableAuth: true`).
It turns enforcement off whatever the settings say, so the provider can be fixed.
Remove it and restart afterwards.

## How "available" and "claimed" are decided

Taken from the controller code at v1.0.6, not from a label: a warm pool creates
each `Sandbox` with a controller owner reference to the `SandboxWarmPool`. When a
claim adopts one, the controller replaces that owner reference with one to the
`SandboxClaim` and drops the `agents.x-k8s.io/warm-pool-sandbox` label. So:

- controller owner `SandboxWarmPool` → available
- controller owner `SandboxClaim` → claimed (warm or cold, per `agents.x-k8s.io/launch-type`)
- no owner → standalone `Sandbox`

## Run locally

Node.js 20.9 or later, and a kubeconfig whose current context points at the tenant
cluster (for example, after `vcluster platform connect vcluster <name>`).

```bash
npm install
npm run dev                                  # http://localhost:3000
VBOX_KUBE_CONTEXT=<context> npm run dev      # a context other than the current one
```

The kubeconfig is read once per server process: restart `npm run dev` after
switching contexts.

Checks:

```bash
npm run lint
npm run typecheck
npm run build
```

## Permissions

vBox only reads from the cluster, with one exception: its own settings Secret. The
Helm chart grants exactly the calls it makes, to the ServiceAccount `vbox`:

| Scope | API group | Resources | Verbs | For |
| --- | --- | --- | --- | --- |
| ClusterRole | `agents.x-k8s.io` | `sandboxes` | get, list | Lists, detail pages, collector |
| ClusterRole | `extensions.agents.x-k8s.io` | `sandboxclaims`, `sandboxwarmpools`, `sandboxtemplates` | get, list | Lists, detail pages, collector |
| ClusterRole | `""` | `pods`, `persistentvolumeclaims` | list | Sandbox pods, Router pods, workspace volumes |
| ClusterRole | `networking.k8s.io` | `networkpolicies` | list | Sandbox detail pages |
| Role in the router's namespace | `""` | `pods/log` | get | The audit collector follows the Sandbox Router |
| Role in vBox's namespace | `""` | `secrets` | list | Finding the settings Secret by its annotation |
| Role in vBox's namespace | `""` | `secrets`, only the settings Secret by name | update | Saving the Settings page |

No `watch`, `get`, `create` or `delete`. **The one broad grant is `list` on Secrets
in vBox's namespace**: Kubernetes cannot filter Secrets by annotation on the
server, and RBAC cannot limit a list to some of them, so finding the Secret by
annotation means listing, and a list returns every Secret in the namespace with
its data. That is why vBox has a namespace of its own, `vbox-system`, holding
nothing but vBox.
Sandbox pods' logs are not read. A missing permission or CRD shows as an error banner
naming the resource; the rest of the page still renders.

## Container image

```bash
docker build -t vbox-ui:dev .
docker run --rm -p 3000:3000 vbox-ui:dev
```

The image runs `node server.js` as UID/GID 10001 on port 3000 (`PORT` overrides
it) and keeps the audit trail and sign-in data (`audit.db`, `auth.db`) in `/data`. Mount a PersistentVolumeClaim there and run
one replica. In a pod it uses the service account token automatically, so it needs a
ServiceAccount with the permissions above.
`GET /api/healthz` returns `{"status":"ok"}` without touching the Kubernetes API;
use it for liveness and readiness probes. With `readOnlyRootFilesystem: true`,
mount an `emptyDir` at `/app/.next/cache`.

## Helm chart

`../../chart/` (`agent-sandboxes/chart/`) deploys vBox into the cluster it shows, in its dedicated namespace
**`vbox-system`**. Everything namespaced lives there except the router-logs Role,
which has to sit beside the Sandbox Router in `agent-sandbox-system`.

| Object | Notes |
| --- | --- |
| Deployment | One replica, `Recreate`: SQLite on a ReadWriteOnce volume needs a single writer. Non-root (10001), read-only root filesystem, no capabilities, `RuntimeDefault` seccomp |
| Service | `ClusterIP` on port 80 by default (`service.type`, `service.port`) |
| Secret | The OIDC settings, `vbox-oidc` by default, annotated `vbox.vcluster.com/oidc-config: "true"` |
| ServiceAccount | `vbox` |
| ClusterRole, ClusterRoleBinding, Roles, RoleBindings | The permissions above |
| PersistentVolumeClaim | `<release>-data`, mounted at `/data`: the audit trail (`audit.db`) and sessions (`auth.db`). 1 GiB by default (`persistence.*`), kept on uninstall |

```bash
docker build -t <registry>/vbox-ui:0.1.0 . && docker push <registry>/vbox-ui:0.1.0
helm install vbox ../../chart -n default \
  --set image.repository=<registry>/vbox-ui \
  --set publicUrl=https://vbox.example.com
kubectl -n vbox-system port-forward svc/vbox 8080:80
```

**Published:** to a registry of your choice; `<your-registry>` stands for it in the
chart's `image.repository` and the StackTemplate's `vboxChart` default. The "Build and
publish vBox" section of `agent-sandboxes/README.md` has the full steps: build the
image, point the chart at it, push both. The `agent-sandbox` StackTemplate installs
vBox from there (its `vbox` task, parameters `vboxEnabled`, `vboxChart`,
`vboxVersion` and `vboxPublicUrl`), without pull credentials, so both repositories
must be public. To publish a new version, bump `version` and `appVersion` in
`../../chart/Chart.yaml`, then, from this directory:

```bash
docker login <registry-host> && helm registry login <registry-host>
docker buildx build --platform linux/amd64 -t <your-registry>/vbox-ui:<appVersion> --push .
helm package ../../chart && helm push vbox-<version>.tgz oci://<your-registry>
```

**`scripts/install.sh` does all of this** for the demo's agent-sandbox cluster.
It builds the image for the nodes' architecture, pushes it to the `vbox` ECR
repository with a unique tag, and installs or upgrades the release. It confirms the
kube context first (`YES=1` skips that). It passes an ECR token as a pull secret
(`registryCredentials`), because the cluster's nodes have an IAM policy for ECR but
no kubelet ECR credential provider, so they cannot pull a private ECR image on their
own. The token is valid for 12 hours; `SKIP_BUILD=1 TAG=<tag> ./scripts/install.sh`
refreshes it without rebuilding. The script's header lists its other settings.

**The chart creates `vbox-system`.** Helm installs the Namespace before
everything else in the release, with Pod Security `restricted` enforced, like
`agent-sandbox-system` and the sandbox namespace. The vBox pod passes that profile,
which a server-side dry run against a `restricted` namespace confirmed.

**Install the release into another namespace** (`-n default` above). Only Helm's
release record goes there. Helm writes that record before it creates anything, so
it cannot go into a namespace the chart has yet to create, and a `vbox-system` made
by `--create-namespace` would collide with the chart's own. The chart refuses
`-n vbox-system` with a message saying so.

**Uninstalling keeps the namespace.** The Namespace, the settings Secret and the
audit trail's PVC are all annotated `helm.sh/resource-policy: keep`, so a reinstall
picks up the same settings and audit trail. `kubectl delete namespace vbox-system`
removes them for good.

To install into a `vbox-system` that already exists, set `namespace.create=false`
and install the release into it (`-n vbox-system`).

**The settings Secret outlives the chart's values.** `oidc.initial` seeds it on
first install only. On every upgrade the chart re-renders whatever the Secret holds
now, through `lookup`, so `helm upgrade` never reverts a change made in the UI.
`helm.sh/resource-policy: keep` leaves it in place on uninstall. The PVC is kept
the same way, so the audit trail survives a reinstall.

**With Argo CD or `helm template`, `lookup` returns nothing**, so the chart would
render `oidc.initial` and self-heal would revert the UI's changes. Set
`oidc.createSecret=false` there, and create the Secret once yourself (any of the
keys above; missing ones take their defaults). The same applies to a Secret
managed by External Secrets. Either way, give it the annotation, and name it
`oidc.secretName`: vBox finds it by the annotation, but the Role grants `update`
on that name only, so a Secret under another name can be read and not saved.

**The router Role is created in `collector.routerNamespace`** (default
`agent-sandbox-system`), outside the release namespace. Installing the chart
therefore needs permission to create Roles there. With `collector.enabled=false`
it is not created.

| Value | Default | |
| --- | --- | --- |
| `namespace.name` | `vbox-system` | The dedicated namespace every namespaced object goes into |
| `namespace.create` | `true` | The chart creates it (`restricted`, kept on uninstall). Install the release into another namespace |
| `namespace.podSecurity` | `restricted` | Pod Security level enforced on it |
| `registryCredentials.create`, `.registry`, `.username`, `.password` | off | Creates a pull secret in `vbox-system` and uses it |
| `image.repository`, `image.tag` | `vbox-ui`, the app version | No image is published yet; build and push the Dockerfile |
| `publicUrl` | empty | Base of the OIDC redirect URI. Set it once vBox is exposed |
| `oidc.annotation` | `vbox.vcluster.com/oidc-config` | How vBox finds the settings Secret (value `"true"`) |
| `oidc.secretName` | `vbox-oidc` | The name the chart creates it under, and the only one vBox may update |
| `oidc.createSecret` | `true` | `false` to bring your own Secret |
| `oidc.initial.*` | sign-in off | First install only |
| `disableAuth` | `false` | Break-glass `VBOX_AUTH=off` |
| `collector.enabled`, `.routerNamespace`, `.routerSelector` | on, `agent-sandbox-system`, `app.kubernetes.io/name=sandbox-router` | |
| `persistence.enabled`, `.size`, `.storageClassName`, `.existingClaim` | on, `1Gi` | |
| `rbac.create` | `true` | |
