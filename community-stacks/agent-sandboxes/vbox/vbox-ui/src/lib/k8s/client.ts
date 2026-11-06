import * as k8s from "@kubernetes/client-node";

// One KubeConfig per server process. loadFromDefault() reads $KUBECONFIG or
// ~/.kube/config when running locally, and the mounted service account token when
// running in a pod. VBOX_KUBE_CONTEXT selects a context other than the current one.
// Kept on globalThis so `next dev` hot reloads do not re-read the file each time.

interface Clients {
  kc: k8s.KubeConfig;
  custom: k8s.CustomObjectsApi;
  core: k8s.CoreV1Api;
}

const globalForK8s = globalThis as unknown as { __vboxK8s?: Clients };

export function getClients(): Clients {
  if (!globalForK8s.__vboxK8s) {
    const kc = new k8s.KubeConfig();
    kc.loadFromDefault();
    const context = process.env.VBOX_KUBE_CONTEXT;
    if (context) kc.setCurrentContext(context);
    globalForK8s.__vboxK8s = {
      kc,
      custom: kc.makeApiClient(k8s.CustomObjectsApi),
      core: kc.makeApiClient(k8s.CoreV1Api),
    };
  }
  return globalForK8s.__vboxK8s;
}

export interface ClusterInfo {
  context: string;
  server: string;
  // Display name: the tenant cluster name when the server is a vCluster Platform
  // proxy URL, the kubeconfig cluster name otherwise.
  name: string;
  project?: string;
}

export function getClusterInfo(): ClusterInfo {
  const { kc } = getClients();
  const cluster = kc.getCurrentCluster();
  const server = cluster?.server ?? "";
  const context = kc.getCurrentContext() || "in-cluster";
  const platform = server.match(/\/kubernetes\/project\/([^/]+)\/virtualcluster\/([^/]+)/);
  if (platform) {
    return { context, server, name: platform[2], project: platform[1] };
  }
  return { context, server, name: cluster?.name ?? context };
}

export { k8s };
