# offensi/test — ACI gitRepo sidecar PoC repo

Benign-looking repo used to demonstrate root code-execution in the Azure
Container Instances `gitRepo` volume sidecar (`aci-atlas-sidecar-gitrepo`).

The hooks live under `customrepo/hooks/` so they are reachable via the injected
`directory=--config=core.hooksPath=customrepo/hooks` argument. When ACI's sidecar
runs `git clone` as root and checks out the tree, `core.hooksPath` points git at
the attacker-controlled `customrepo/hooks/post-checkout`, which git executes.

- `customrepo/hooks/_dispatch.sh` — NON-BLOCKING entry: detaches the recon and
  returns to git instantly so the container reaches `Running` (no Waiting hang).
- `customrepo/hooks/_recon.sh` — detached payload: in-band proof report + process
  listing across the shared pid namespace + non-destructive cgroup inspection,
  plus an optional out-of-band summary.
- `customrepo/hooks/{post-checkout,reference-transaction,...}` — thin wrappers
  that exec the dispatcher.

This repo is intentionally inert when cloned normally (hooks only fire when the
victim sets `core.hooksPath` to this path — which is exactly what the injection does).
