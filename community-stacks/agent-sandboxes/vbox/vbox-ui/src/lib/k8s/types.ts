// Wire shapes of the Agent Sandbox CRDs (agents.x-k8s.io and
// extensions.agents.x-k8s.io, v1beta1), limited to the fields vbox reads. Taken
// from api/v1beta1 and extensions/api/v1beta1 in kubernetes-sigs/agent-sandbox.
import type {
  V1Container,
  V1NetworkPolicyEgressRule,
  V1NetworkPolicyIngressRule,
  V1PersistentVolumeClaimSpec,
  V1PodSpec,
} from "@kubernetes/client-node";

export const AGENTS_GROUP = "agents.x-k8s.io";
export const EXTENSIONS_GROUP = "extensions.agents.x-k8s.io";
export const API_VERSION = "v1beta1";

// Labels and annotations the controllers write (api/v1beta1/sandbox_types.go).
export const LABEL_LAUNCH_TYPE = "agents.x-k8s.io/launch-type";
export const LABEL_CREATED_BY = "agents.x-k8s.io/created-by";
export const LABEL_WARM_POOL = "agents.x-k8s.io/warm-pool-sandbox";
export const LABEL_SANDBOX_NAME_HASH = "agents.x-k8s.io/sandbox-name-hash";
export const LABEL_CLAIM_UID = "agents.x-k8s.io/claim-uid";
export const ANNOTATION_TEMPLATE_REF = "agents.x-k8s.io/sandbox-template-ref";
export const ANNOTATION_POD_NAME = "agents.x-k8s.io/pod-name";

export interface OwnerReference {
  apiVersion: string;
  kind: string;
  name: string;
  uid: string;
  controller?: boolean;
}

export interface ObjectMeta {
  name: string;
  namespace: string;
  uid: string;
  creationTimestamp: string;
  deletionTimestamp?: string;
  generation?: number;
  labels?: Record<string, string>;
  annotations?: Record<string, string>;
  ownerReferences?: OwnerReference[];
  managedFields?: unknown;
  resourceVersion?: string;
}

export interface Condition {
  type: string;
  status: "True" | "False" | "Unknown";
  reason?: string;
  message?: string;
  lastTransitionTime?: string;
  observedGeneration?: number;
}

export interface PodTemplate {
  metadata?: { labels?: Record<string, string>; annotations?: Record<string, string> };
  spec: V1PodSpec;
}

export interface PersistentVolumeClaimTemplate {
  metadata: { name?: string; labels?: Record<string, string>; annotations?: Record<string, string> };
  spec: V1PersistentVolumeClaimSpec;
}

export interface Sandbox {
  apiVersion: string;
  kind: "Sandbox";
  metadata: ObjectMeta;
  spec: {
    podTemplate: PodTemplate;
    volumeClaimTemplates?: PersistentVolumeClaimTemplate[];
    service?: boolean;
    shutdownTime?: string;
    shutdownPolicy?: string;
    operatingMode?: string;
  };
  status?: {
    serviceFQDN?: string;
    service?: string;
    conditions?: Condition[];
    selector?: string;
    podIPs?: string[];
    nodeName?: string;
  };
}

export interface SandboxClaim {
  apiVersion: string;
  kind: "SandboxClaim";
  metadata: ObjectMeta;
  spec: {
    warmPoolRef: { name: string };
    lifecycle?: {
      shutdownTime?: string;
      ttlSecondsAfterFinished?: number;
      shutdownPolicy?: string;
    };
    additionalPodMetadata?: { labels?: Record<string, string>; annotations?: Record<string, string> };
    env?: { name: string; value: string; containerName?: string }[];
    volumeClaimTemplates?: PersistentVolumeClaimTemplate[];
  };
  status?: {
    conditions?: Condition[];
    sandbox?: { name?: string; podIPs?: string[]; serviceFQDN?: string };
  };
}

export interface SandboxWarmPool {
  apiVersion: string;
  kind: "SandboxWarmPool";
  metadata: ObjectMeta;
  spec: {
    replicas?: number;
    sandboxTemplateRef: { name: string };
    updateStrategy?: { type?: string };
  };
  status?: {
    replicas?: number;
    readyReplicas?: number;
    selector?: string;
    observedGeneration?: number;
  };
}

export interface SandboxTemplate {
  apiVersion: string;
  kind: "SandboxTemplate";
  metadata: ObjectMeta;
  spec: {
    podTemplate: PodTemplate;
    volumeClaimTemplates?: PersistentVolumeClaimTemplate[];
    service?: boolean;
    networkPolicy?: {
      ingress?: V1NetworkPolicyIngressRule[];
      egress?: V1NetworkPolicyEgressRule[];
    };
    networkPolicyManagement?: string;
    envVarsInjectionPolicy?: string;
    volumeClaimTemplatesPolicy?: string;
  };
}

export interface List<T> {
  items: T[];
}

export type { V1Container };
