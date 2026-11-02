# DSO202 Assignment 3 — Helm and Kustomize



## 1. Aim

The aim of this assignment is to package and deploy the same nginx web application in two ways:

1. **Helm:** write a versioned, configurable chart (`webapp`), validate it, install it as `dev` and `prod`
   releases, and run it through the release lifecycle (test, upgrade, rollback, uninstall).
2. **Kustomize:** keep the shared Kubernetes resources in one **base**, describe the `dev`, `staging` and
   `prod` differences in thin **overlays**, and use transformers, both patch styles and generators.

All work was done on a local three-node kind cluster.

## 2. Environment

| Tool | Version |
|---|---|
| Helm | v4.3.1 |
| kubectl (with built-in Kustomize v5.8.1) | v1.37.2 |
| kind | v0.32.0 |
| Kubernetes (cluster nodes) | v1.36.1 |
| Host | macOS (Apple Silicon), Docker Desktop |


![Tool versions](screenshots/01-tool-versions.png)
*Figure 1 — Helm 4, kubectl and kind versions.*

The cluster is defined in [cluster/kind-cluster.yaml](cluster/kind-cluster.yaml): one control-plane node, two
workers, and host ports **30080** (Helm dev release) and **30081** (Kustomize dev overlay) mapped into the cluster.

![kind cluster](screenshots/02-kind-cluster-nodes.png)
*Figure 2 — Cluster `dso202` created; all three nodes are `Ready`.*

## 3. Repository structure

```
.
├── cluster/kind-cluster.yaml          # 3-node kind cluster, ports 30080 and 30081
├── helm/
│   ├── environments/{dev,prod}.yaml   # per-environment values (deployment config, kept outside the chart)
│   └── webapp/                        # the Helm chart
│       ├── Chart.yaml  values.yaml  values.schema.json  .helmignore
│       └── templates/
│           ├── _helpers.tpl  configmap.yaml  deployment.yaml  service.yaml  NOTES.txt
│           └── tests/test-connection.yaml
├── kustomize/
│   ├── base/                          # deployment, service, index.html, configMapGenerator
│   └── overlays/{dev,staging,prod}/   # namespace, labels, replicas, images, generators, patches
├── screenshots/                       # evidence used in this report
└── guide.md                           # step-by-step commands used to produce the screenshots
```

---

## 4. Part 1 — Helm

### 4.1 Chart design

![Chart structure](screenshots/03-helm-chart-structure.png)
*Figure 3 — Files in the `webapp` chart and its `Chart.yaml`.*

| File | Purpose |
|---|---|
| `Chart.yaml` | `apiVersion: v2` chart. `version: 0.1.0` is the **chart** version; `appVersion: "1.30-alpine"` is the **application** version (quoted so YAML keeps it a string). `kubeVersion: ">=1.30.0-0"` refuses older clusters. |
| `values.yaml` | The chart's configuration interface: replicas, image, page text, Service type/port, resources. `page.environment` is deliberately empty so an environment must be chosen. |
| `_helpers.tpl` | Named templates: `webapp.fullname` (truncated to 63 chars), `webapp.selectorLabels` (small and stable, since Deployment selectors are immutable), `webapp.labels` (full recommended `app.kubernetes.io/*` set), and `webapp.environment`, which uses `required`. |
| `configmap.yaml` | The HTML page, built from values and built-in objects (`.Release`, `.Chart`). |
| `deployment.yaml` | nginx with probes and resources. A `checksum/config` annotation hashes the ConfigMap so a content change rolls the Pods. The image tag defaults to `.Chart.AppVersion`. |
| `service.yaml` | ClusterIP or NodePort; `nodePort` is emitted only when the type is NodePort and a port is given. |
| `NOTES.txt` | Tells the operator how to reach the app (curl for NodePort, port-forward for ClusterIP). |
| `tests/test-connection.yaml` | A `helm.sh/hook: test` Pod that fetches the page and checks the environment. |
| `values.schema.json` | JSON Schema validating types and permitted values before any template is rendered. |

Environment values live **outside** the chart, because they belong to the deployment, not the package:

| Value | dev ([dev.yaml](helm/environments/dev.yaml)) | prod ([prod.yaml](helm/environments/prod.yaml)) |
|---|---|---|
| `replicaCount` | 1 | 3 |
| Service | NodePort 30080 | ClusterIP (default) |
| CPU request / limit | 50m / 200m (default) | 100m / 500m |
| Message | "Development build - not for customers" | "Production" |

### 4.2 Validation before installing

**Missing required value.** Rendering without an environment stops with the chart's own message. The location
shown is the test Pod, because it is the template that *included* the helper.

![Required value error](screenshots/04-helm-required-value-error.png)
*Figure 4 — `required` stops rendering when `page.environment` is not set.*

**Lint and render every environment.** `helm lint` on its own only *warns* about a missing required value, so
CI must also run `helm template` for every values file. Both environments pass; the `[INFO] icon is
recommended` line is only a suggestion.

![Lint and template](screenshots/05-helm-lint-template-all-envs.png)
*Figure 5 — Lint and render succeed for `dev` and `prod`.*

**Rendered output.** The Deployment uses the release name alone (`webapp-dev` already contains the chart
name), carries the full label set, selects on the two stable labels only, gets its image tag from
`appVersion` (`nginx:1.30-alpine`), and has a repeatable `checksum/config` hash. `toYaml` sorted `limits`
before `requests`.

![Rendered Deployment](screenshots/06-helm-template-render.png)
*Figure 6 — `helm template -s templates/deployment.yaml` for the dev release.*

**Values schema.** An unquoted `tag: 1.30` is read by YAML as the number 1.3. Without a schema this would
silently render `nginx:1.3`. The schema rejects it, and it reports all three invalid values in the second
command at once.

![Schema validation](screenshots/07-helm-schema-validation.png)
*Figure 7 — `values.schema.json` rejecting a numeric tag, `replicaCount=0`, `LoadBalancer` and an unknown environment.*

**Values precedence.** `--set replicaCount=2` overrides `dev.yaml`. Layering `-f dev.yaml -f prod.yaml` gives
prod's `replicas: 3` but keeps dev's `NodePort 30080`, because `prod.yaml` never mentions `service`. Maps
merge deeply, so environment files must be used on their own, not stacked.

![Values precedence](screenshots/08-helm-values-precedence.png)
*Figure 8 — `--set` beats `-f`; layered environment files leak settings.*

**API-server dry run.** Piping the render into `kubectl apply --dry-run=server` makes the API server validate
every object without saving it. This is the only check that catches misspelled Kubernetes fields.

![Server dry run](screenshots/09-helm-server-dry-run.png)
*Figure 9 — All prod objects accepted by the API server (`created (server dry run)`).*

| Check | Missing required value | Wrong value type | Bad indentation | Unknown Kubernetes field |
|---|---|---|---|---|
| `helm lint` | warning only | yes (schema) | yes | no |
| `helm template` | yes | yes (schema) | yes | no |
| `helm template \| kubectl apply --dry-run=server` | yes | yes (schema) | yes | **yes** |

### 4.3 Installing the releases

`helm upgrade --install` is idempotent: it installs the first time and upgrades afterwards, so the same
command is safe in CI. `--wait` returns only once the Pods are ready.

![Install dev](screenshots/10-helm-install-dev.png)
*Figure 10 — `webapp-dev` installed, revision 1. NOTES shows the NodePort curl command.*

![Install prod](screenshots/11-helm-install-prod.png)
*Figure 11 — `webapp-prod` installed with 3 replicas. NOTES shows port-forward because prod uses ClusterIP.*

![List and objects](screenshots/12-helm-list-and-objects.png)
*Figure 12 — Both releases `deployed`; dev has 1 Pod behind NodePort `80:30080`, prod has 3 Pods behind a ClusterIP Service.*

![Curl dev](screenshots/13-helm-curl-dev.png)
*Figure 13 — The dev page served on `localhost:30080`, showing environment, release, namespace and chart version.*

### 4.4 Testing and inspecting the release

`helm test` runs the hook Pod, which fetches the page through the Service and greps for the expected
environment. Both suites succeeded.

![Helm test](screenshots/14-helm-test.png)
*Figure 14 — `helm test` passes for both releases (`Phase: Succeeded`).*

`helm get values` shows only the user-supplied values, and `helm get manifest` shows exactly what was sent to
the API server, with the template each object came from. Every revision is stored in a Secret named
`sh.helm.release.v1.<release>.v<revision>`. Anyone who can read Secrets in the namespace can recover these
values, so real passwords should not be passed as plain values.

![Get values and manifest](screenshots/15-helm-get-values-manifest.png)
*Figure 15 — Release values, rendered manifest sources, and the release-record Secret.*

### 4.5 Upgrade and rollback

An upgrade changing the page message created **revision 2**. Rolling back to revision 1 did not delete
revision 2: it created **revision 3**, a copy of revision 1, so the history records everything in order.

![Upgrade](screenshots/16-helm-upgrade.png)
*Figure 16 — Upgrade to revision 2 (`Upgrade complete`).*

![Rollback and history](screenshots/17-helm-rollback-history.png)
*Figure 17 — `helm history`: 1 superseded, 2 superseded, 3 deployed (`Rollback to 1`).*

---

## 5. Part 2 — Kustomize

### 5.1 Base and overlay design

> Base stores what is shared. Overlay stores what is different. Kustomize renders the final YAML.

The **base** ([kustomize/base](kustomize/base)) holds the Deployment, the Service and a `configMapGenerator`
for `index.html`. Each **overlay** imports `../../base` and contains only what differs:

| Setting | dev | staging | prod | Kustomize feature |
|---|---|---|---|---|
| Namespace | webapp-dev | webapp-staging | webapp-prod | `namespace:` transformer |
| Replicas | 1 | 2 | 4 | `replicas:` |
| Image tag | 1.29-alpine (experimental) | 1.28-alpine (release candidate) | 1.27-alpine (pinned) | `images:` |
| Labels | environment + `debug: "true"` | environment | environment | `labels:` with `includeSelectors: false` |
| Page | dev HTML | staging HTML | prod HTML | `configMapGenerator` with `behavior: replace` |
| Service | NodePort 30081 | ClusterIP | ClusterIP | strategic merge patch (dev) |
| Extra config | `app-config` from `app.env` + `envFrom` | — | — | `configMapGenerator` (`envs:`) + inline JSON 6902 patch |
| Resources | base | base | 200m–500m CPU | strategic merge patch (prod) |
| Annotation / probe | — | — | `training.example.com~1owner`, remove `periodSeconds` | JSON 6902 patch (`add`, `remove`) |
| Secret | — | — | `app-secret` (dummy values) | `secretGenerator` |

`includeSelectors: false` is used on purpose. Adding labels to selectors would change immutable Deployment
selectors and Service routing.

![Kustomize structure](screenshots/18-kustomize-structure.png)
*Figure 18 — Base and overlay files, with the base and prod `kustomization.yaml`.*

### 5.2 Rendering first

`kubectl kustomize` renders locally without touching the cluster. In prod it shows the namespace on every
object, the hashed generated names (`web-content-tkt999c67d`, `app-secret-mhmb5k485t`), the base64 Secret
data (base64 is **encoding, not encryption**), and the `training.example.com/owner` annotation added by
the JSON 6902 patch (`/` escaped as `~1` in the path).

![Render prod](screenshots/19-kustomize-render-prod.png)
*Figure 19 — Rendered prod overlay.*

![Render dev](screenshots/20-kustomize-render-dev.png)
*Figure 20 — Dev differences: `replicas: 1`, `nginx:1.29-alpine`, `NodePort 30081`, `debug: "true"`, and the Deployment rewritten to the hashed `web-content-67bm989859` and `app-config-db244k5chh` names.*

### 5.3 Diff, apply and verify

`kubectl diff -k` asks the API server what would change. New objects appear entirely as `+` lines; the
already-existing Namespace shows only the two labels the overlay would add.

![Diff](screenshots/21-kustomize-diff.png)
*Figure 21 — `kubectl diff -k overlays/dev` before applying.*

![Apply](screenshots/22-kustomize-apply.png)
*Figure 22 — All three overlays applied with `kubectl apply -k`.*

![Verify](screenshots/23-kustomize-verify.png)
*Figure 23 — Deployments in all namespaces, the dev objects, and the prod generated ConfigMap and Secret.*

Figure 23 was taken about 30 seconds after applying, so prod (`0/4`) and staging (`1/2`) were still pulling
their images. When the same overlays were checked with `kubectl rollout status` during testing, all replicas
became ready (dev 1/1, staging 2/2, prod 4/4).

![Curl dev](screenshots/24-kustomize-curl-dev.png)
*Figure 24 — Dev page on `localhost:30081`, and `LOG_LEVEL=debug` injected from the generated `app-config` ConfigMap.*

### 5.4 Generated-name hash triggers a rollout

> Content changes → hash changes → reference changes → Pod template changes → rollout.

Editing `overlays/dev/index.html` changed the generated name from `web-content-67bm989859` to
`web-content-dtf8922m79`. Kustomize rewrote the Deployment's volume reference to match, which changed the
Pod template, and the Deployment rolled out a new ReplicaSet (`webapp-66646c4cc` is new, `webapp-6fb8b87789`
was scaled to 0). No manual restart was needed.

![Hash rollout](screenshots/25-kustomize-hash-rollout.png)
*Figure 25 — ConfigMap content change producing a new hash and a new ReplicaSet.*

Reverting the file restored the original name. The old ConfigMap was still present (`unchanged`), and the
Deployment was `configured` back to it.

![Hash revert](screenshots/25b-kustomize-hash-revert.png)
*Figure 26 — Reverting the change rolls the Deployment back to the original ConfigMap.*

### 5.5 Clean up

`kubectl delete -k` removed every object the overlays created, including the namespaces. `helm uninstall`
removed both releases and their release records. The final `helm list -A` is empty.

![Cleanup](screenshots/26-cleanup.png)
*Figure 27 — All Kustomize objects deleted and both Helm releases uninstalled.*

---

## 6. Helm compared with Kustomize

| Aspect | Helm | Kustomize |
|---|---|---|
| Method | Renders Go templates with values | Patches plain YAML: a base plus overlays |
| Input files | Templates, not valid YAML until rendered | Valid Kubernetes YAML only |
| Built into kubectl | No, separate binary | Yes (`kubectl apply -k`) |
| Records what was installed | Yes, a release record per revision | No |
| Rollback | `helm rollback <release> <revision>` | Revert the Git commit and apply again |
| Validation | `required`, `values.schema.json`, `helm lint`, `helm test` | Render and review (`kubectl kustomize`, `kubectl diff`) |
| Config change → restart | `checksum/config` annotation written in the template | Automatic, through the generated-name hash |
| Best suited to | Packaging software for others, third-party charts | Environment variants of a team's own manifests |

The two are complementary. A common industry pattern is to install a third-party chart with Helm and apply
organisation-specific patches with Kustomize.

## 7. Problems encountered and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| `kubectl diff -k overlays/dev` failed with `namespaces "webapp-dev" not found` | A server-side diff dry-runs each object, and a dry run never creates the Namespace in the same bundle | Create the namespace first with `kubectl apply -f overlays/dev/namespace.yaml`, then diff |
| Server dry run for prod failed with `namespaces "dso202-prod" not found` | Same reason: the release namespace did not exist yet | `kubectl create namespace dso202-prod` before the dry run |
| `helm lint` passes a chart that cannot render | `lint` reports a missing `required` value only as a warning and exits 0 | Always run `helm template` for every environment file as well |
| `curl` immediately after an upgrade or rollback sometimes printed nothing | The NodePort was briefly routing to Pods that were still being replaced | Wait a few seconds and repeat; `helm history` and `helm test` are the reliable evidence |
| Unquoted `tag: 1.30` would deploy `nginx:1.3` | YAML parses `1.30` as a float | `values.schema.json` requires `image.tag` to be a string |

## 8. Conclusion

The same nginx application was deployed with both tools on a three-node kind cluster.

- **Helm** packaged the manifests as a versioned chart with a documented and validated configuration
  interface. Errors were caught before installation through `required`, a JSON Schema, linting and a
  server-side dry run. Releases were installed per environment, tested with `helm test`, upgraded, and
  rolled back with a complete revision history.
- **Kustomize** kept one boring base and three thin overlays, with no copied Deployment between
  environments. Transformers, strategic merge and JSON 6902 patches, and generators expressed every
  environment difference. The generated-name hash restarted Pods automatically whenever configuration
  content changed.

The key habits learned were: pin versions, keep every value in version-controlled files, and always render
and review the final YAML before it reaches the cluster.

---
