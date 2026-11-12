// Detail page URLs, one per object kind.
const path = (base: string) => (namespace: string, name: string) =>
  `/${base}/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`;

export const hrefs = {
  sandbox: path("sandboxes"),
  claim: path("claims"),
  warmPool: path("warm-pools"),
  template: path("templates"),
  audit: path("audit"),
};
