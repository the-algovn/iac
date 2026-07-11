# k3s GitOps Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fully IaC-managed k3s cluster on the Pi `algovn` where every change flows git → CI → Argo CD, per the approved spec at `docs/superpowers/specs/2026-07-11-k3s-gitops-cluster-design.md`.

**Architecture:** Three strict layers — Ansible provisions the node and k3s (Layer 0); a one-time bootstrap installs Argo CD and a root app-of-apps (Layer 1); everything else (platform components, workloads) reconciles from this repo via sync-waved Argo Applications (Layer 2). Public traffic enters via Cloudflare Tunnel → Traefik; secrets live in git only as SealedSecrets.

**Tech Stack:** k3s (sqlite), Ansible (builtin modules only), Argo CD (slim kustomize install), Sealed Secrets, cloudflared, external-dns, cert-manager, VictoriaMetrics k8s stack + Grafana, Loki + Alloy, argocd-image-updater, GitHub Actions, Renovate.

## Global Constraints

- **Execution host**: everything runs ON the Pi (`algovn`, `192.168.102.202`) as user `ducle` (passwordless sudo). Repo checkout: `/home/ducle/iac`.
- **Public repo — zero plaintext secrets**: only `SealedSecret` CRs are committed. Transient plaintext goes under `~/.secrets/` (mode 700) and is `shred -u`'d after sealing. `gitleaks` gates every commit.
- **GitOps flow**: after Task 5, no `kubectl apply` against the cluster except `bootstrap/` — all changes are commit → validate → push to `main`; Argo auto-syncs (≤3 min) or force with `argocd app sync <name>`.
- **Validate before every push**: `scripts/validate.sh` must pass (same gates as CI).
- **RAM discipline**: every container declares resource requests + limits. Platform budget ~2.6GB total (spec §3 table).
- **arm64 only**: all images/binaries are linux/arm64 (aarch64).
- **Pinned versions everywhere**: steps say "example — substitute the version the discovery command prints". Never write `latest` into git. Renovate owns bumps after Task 19.
- **Containers**: use `podman`, never `docker`, for any local container need.
- **Domain**: `algovn.com` (Cloudflare-managed). Hosts: `argocd.`, `grafana.`, `homepage.`, `uptime.algovn.com`.
- **`[NEEDS USER]` steps**: require the human (browser logins, tokens, password manager). Orchestrator: pause and collect these from the user before/while dispatching that task — subagents cannot do them.
- **Argo CLI**: except in Task 5 (which logs in via port-forward within one step), run every `argocd app wait/list/sync` in this plan with the `--core` flag appended (e.g. `argocd app wait cloudflared --core --timeout 300`) — `--core` talks directly to the cluster via kubeconfig, no port-forward or login needed in fresh shells.
- **Naming registry** (exact strings used across tasks): namespaces `argocd`, `sealed-secrets`, `cert-manager`, `cloudflared`, `external-dns`, `monitoring`, `logging`, `image-updater`, `homepage`, `uptime-kuma`; secrets `cloudflare-api-token` (in cert-manager AND external-dns ns, key `token`), `tunnel-credentials` (cloudflared ns, key `credentials.json`), `grafana-admin` (monitoring ns, keys `admin-user`, `admin-password`), `alertmanager-config` (monitoring ns, key `alertmanager.yaml`); tunnel name `algovn`; repo URL in all Applications: `https://github.com/the-algovn/iac.git`.

---

### Task 1: Repo skeleton + validation harness

**Files:**
- Create: `scripts/validate.sh`, `.gitignore`, `README.md`
- Create (empty keeps): `clusters/algovn/platform/.gitkeep`, `clusters/algovn/apps/.gitkeep`

**Interfaces:**
- Produces: `scripts/validate.sh` (arg-less, exit 0 = pass) — every later task runs it before pushing. Tools installed at `/usr/local/bin`: `kustomize`, `kubeconform`, `gitleaks`, `helm`, `actionlint`.

- [ ] **Step 1: Install validation toolchain (arm64 binaries)**

```bash
cd ~ && mkdir -p ~/.secrets && chmod 700 ~/.secrets
# kustomize
curl -sL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
# kubeconform
KC_VER=$(curl -s https://api.github.com/repos/yannh/kubeconform/releases/latest | grep -oP '"tag_name": "\K[^"]+')
curl -sL "https://github.com/yannh/kubeconform/releases/download/${KC_VER}/kubeconform-linux-arm64.tar.gz" | sudo tar xz -C /usr/local/bin kubeconform
# gitleaks
GL_VER=$(curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
curl -sL "https://github.com/gitleaks/gitleaks/releases/download/v${GL_VER}/gitleaks_${GL_VER}_linux_arm64.tar.gz" | sudo tar xz -C /usr/local/bin gitleaks
# helm
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# actionlint
AL_VER=$(curl -s https://api.github.com/repos/rhysd/actionlint/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
curl -sL "https://github.com/rhysd/actionlint/releases/download/v${AL_VER}/actionlint_${AL_VER}_linux_arm64.tar.gz" | sudo tar xz -C /usr/local/bin actionlint
kustomize version && kubeconform -v && gitleaks version && helm version --short && actionlint --version
```

Expected: each tool prints a version, no errors.

- [ ] **Step 2: Write `.gitignore` and `README.md`**

`.gitignore`:
```gitignore
*.plaintext.yaml
*.key
kubeconfig*
.secrets/
__pycache__/
```

`README.md`:
```markdown
# the-algovn/iac

IaC + GitOps source of truth for the `algovn` k3s cluster (Raspberry Pi 5).

- **Spec**: docs/superpowers/specs/2026-07-11-k3s-gitops-cluster-design.md
- **Layers**: `ansible/` (node) → `bootstrap/` (one-time Argo CD) → `clusters/` + `platform/` + `apps/` (GitOps, Argo-managed)
- **Runbooks**: docs/runbooks/
- **Rule**: no plaintext secrets, ever — SealedSecrets only. `scripts/validate.sh` before every push.
```

- [ ] **Step 3: Write `scripts/validate.sh`**

```bash
#!/usr/bin/env bash
# Repo-wide validation: kustomize builds, schema checks, secret scan, workflow lint.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> kustomize build (all kustomizations)"
while IFS= read -r f; do
  d=$(dirname "$f")
  kustomize build "$d" > /dev/null || { echo "FAIL: kustomize build $d"; exit 1; }
  echo "ok: $d"
done < <(find . -name kustomization.yaml -not -path './.git/*')

echo "==> kubeconform (rendered kustomizations + raw manifest dirs)"
SCHEMAS=(-schema-location default
         -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
while IFS= read -r f; do
  kustomize build "$(dirname "$f")" | kubeconform "${SCHEMAS[@]}" -ignore-missing-schemas -strict - \
    || { echo "FAIL: kubeconform $(dirname "$f")"; exit 1; }
done < <(find . -name kustomization.yaml -not -path './.git/*')
for dir in clusters; do
  [ -d "$dir" ] && find "$dir" -name '*.yaml' -not -name kustomization.yaml -print0 \
    | xargs -0 -r kubeconform "${SCHEMAS[@]}" -ignore-missing-schemas -strict
done

echo "==> actionlint"
[ -d .github/workflows ] && actionlint || true
[ -d templates ] && find templates -name '*.yaml' -exec actionlint {} + 2>/dev/null || true

echo "==> gitleaks"
gitleaks detect --no-banner --redact

echo "PASS"
```

```bash
chmod +x scripts/validate.sh
mkdir -p clusters/algovn/platform clusters/algovn/apps
touch clusters/algovn/platform/.gitkeep clusters/algovn/apps/.gitkeep
```

- [ ] **Step 4: Run validation (expect trivial pass)**

Run: `scripts/validate.sh`
Expected: `==> gitleaks` section runs, final line `PASS`.

- [ ] **Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: repo skeleton + validation harness"
git push -u origin main
```

---

### Task 2: CI workflow, pre-commit, Renovate config

**Files:**
- Create: `.github/workflows/ci.yaml`, `.pre-commit-config.yaml`, `renovate.json`

**Interfaces:**
- Consumes: `scripts/validate.sh` (Task 1).
- Produces: GitHub check named **`validate`** (Task 19 marks it required). `renovate.json` (inert until Task 19 installs the app).

- [ ] **Step 1: Write `.github/workflows/ci.yaml`**

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  validate:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Install tools
        run: |
          set -euo pipefail
          curl -sL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
          KC_VER=$(curl -s https://api.github.com/repos/yannh/kubeconform/releases/latest | grep -oP '"tag_name": "\K[^"]+')
          curl -sL "https://github.com/yannh/kubeconform/releases/download/${KC_VER}/kubeconform-linux-arm64.tar.gz" | sudo tar xz -C /usr/local/bin kubeconform
          GL_VER=$(curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
          curl -sL "https://github.com/gitleaks/gitleaks/releases/download/v${GL_VER}/gitleaks_${GL_VER}_linux_arm64.tar.gz" | sudo tar xz -C /usr/local/bin gitleaks
          AL_VER=$(curl -s https://api.github.com/repos/rhysd/actionlint/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
          curl -sL "https://github.com/rhysd/actionlint/releases/download/v${AL_VER}/actionlint_${AL_VER}_linux_arm64.tar.gz" | sudo tar xz -C /usr/local/bin actionlint
      - name: Validate
        run: scripts/validate.sh
```

- [ ] **Step 2: Write `.pre-commit-config.yaml`**

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.0   # example — substitute: git ls-remote --tags https://github.com/gitleaks/gitleaks | tail -1
    hooks:
      - id: gitleaks
```

```bash
sudo apt-get install -y pre-commit || pipx install pre-commit
pre-commit install
```

- [ ] **Step 3: Write `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "timezone": "Asia/Ho_Chi_Minh",
  "argocd": { "managerFilePatterns": ["/^clusters/.+\\.yaml$/"] },
  "packageRules": [
    { "matchUpdateTypes": ["patch", "minor"], "groupName": "all non-major", "schedule": ["before 9am on saturday"] },
    { "matchUpdateTypes": ["major"], "dependencyDashboardApproval": true }
  ]
}
```

- [ ] **Step 4: Validate, commit, push, watch CI**

```bash
scripts/validate.sh && git add -A && git commit -m "ci: validation workflow, pre-commit gitleaks, renovate config" && git push
gh run watch --repo the-algovn/iac --exit-status $(gh run list --repo the-algovn/iac -L1 --json databaseId -q '.[0].databaseId')
```

Expected: run concludes `✓ ... validate`. If the `ubuntu-24.04-arm` runner label is unavailable, change `runs-on` to `ubuntu-latest` (tools above are then amd64: drop `-arm64`/`arm64` from the three download URLs → `-amd64`/`x86_64` per each project's naming) and re-push.

---

### Task 3: Ansible layer — base + zram roles, applied to algovn

**Files:**
- Create: `ansible/ansible.cfg`, `ansible/inventory.yml`, `ansible/site.yml`
- Create: `ansible/roles/base/tasks/main.yml`, `ansible/roles/base/files/99-k8s.conf`
- Create: `ansible/roles/zram/tasks/main.yml`, `ansible/roles/zram/files/zram-generator.conf`

**Interfaces:**
- Produces: `ansible-playbook -i inventory.yml site.yml` idempotent entrypoint; inventory groups `server` (algovn) and `agents` (empty, for future nodes). Tags: `base`, `zram`, `k3s`.

- [ ] **Step 1: Install Ansible**

```bash
sudo apt-get update && sudo apt-get install -y ansible
ansible --version | head -1
```

Expected: `ansible [core 2.1x.x]`.

- [ ] **Step 2: Write config, inventory, playbook**

`ansible/ansible.cfg`:
```ini
[defaults]
inventory = inventory.yml
host_key_checking = False
stdout_callback = yaml
```

`ansible/inventory.yml`:
```yaml
all:
  children:
    server:
      hosts:
        algovn:
          ansible_host: 192.168.102.202
          ansible_connection: local
    agents:
      hosts: {}   # future nodes: name + ansible_host (ssh)
  vars:
    ansible_user: ducle
    k3s_version: ""   # set in Task 4 step 1
```

`ansible/site.yml`:
```yaml
- name: Base OS + zram (all nodes)
  hosts: all
  become: true
  roles:
    - { role: base, tags: [base] }
    - { role: zram, tags: [zram] }

- name: k3s server
  hosts: server
  become: true
  roles:
    - { role: k3s_server, tags: [k3s] }

- name: k3s agents
  hosts: agents
  become: true
  roles:
    - { role: k3s_agent, tags: [k3s] }
```

(k3s roles arrive in Task 4 — until then run with `--tags base,zram`.)

- [ ] **Step 3: Write base role**

`ansible/roles/base/files/99-k8s.conf`:
```conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 262144
vm.swappiness = 100
```

`ansible/roles/base/tasks/main.yml`:
```yaml
- name: Install base packages
  ansible.builtin.apt:
    name: [curl, unattended-upgrades, nfs-common, open-iscsi, jq]
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Enable unattended security upgrades
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
    mode: "0644"

- name: Kernel params for k8s
  ansible.builtin.copy:
    src: 99-k8s.conf
    dest: /etc/sysctl.d/99-k8s.conf
    mode: "0644"
  notify: reload sysctl

- name: Flush handlers
  ansible.builtin.meta: flush_handlers
```

`ansible/roles/base/handlers/main.yml` (Create):
```yaml
- name: reload sysctl
  ansible.builtin.command: sysctl --system
```

- [ ] **Step 4: Write zram role**

`ansible/roles/zram/files/zram-generator.conf`:
```ini
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
```

`ansible/roles/zram/tasks/main.yml`:
```yaml
- name: Install systemd zram generator
  ansible.builtin.apt:
    name: systemd-zram-generator
    state: present

- name: Configure zram0
  ansible.builtin.copy:
    src: zram-generator.conf
    dest: /etc/systemd/zram-generator.conf
    mode: "0644"
  register: zram_conf

- name: Activate zram0
  ansible.builtin.systemd:
    name: systemd-zram-setup@zram0.service
    state: "{{ 'restarted' if zram_conf.changed else 'started' }}"
    daemon_reload: true
```

- [ ] **Step 5: Syntax-check, run, verify**

```bash
cd ~/iac/ansible
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --tags base,zram
swapon --show && sysctl net.ipv4.ip_forward
```

Expected: playbook `failed=0`; `swapon --show` lists `/dev/zram0` (~2G, prio 100); `net.ipv4.ip_forward = 1`. Re-run playbook → `changed=0` (idempotent).

- [ ] **Step 6: Validate, commit, push**

```bash
cd ~/iac && scripts/validate.sh && git add -A && git commit -m "feat(ansible): base + zram roles, algovn inventory" && git push
```

---

### Task 4: k3s roles + fresh k3s install

**Files:**
- Create: `ansible/roles/k3s_server/tasks/main.yml`, `ansible/roles/k3s_server/templates/config.yaml.j2`
- Create: `ansible/roles/k3s_agent/tasks/main.yml`, `ansible/roles/k3s_agent/templates/config.yaml.j2`
- Modify: `ansible/inventory.yml` (set `k3s_version`)

**Interfaces:**
- Consumes: Task 3 playbook/tags.
- Produces: running k3s server (systemd unit `k3s`); kubeconfig at `~/.kube/config` for user `ducle`; agent role joining via `https://192.168.102.202:6443` + node-token (future nodes).

- [ ] **Step 1: Pin k3s version in inventory**

```bash
curl -s https://update.k3s.io/v1-release/channels | jq -r '.data[] | select(.id=="stable").latest'
```

Expected output like `v1.33.5+k3s1` (example — use what it prints). Set in `ansible/inventory.yml`: `k3s_version: "v1.33.5+k3s1"`.

- [ ] **Step 2: Remove stale k3s install (destructive — stale data only, spec §1 mandates fresh)**

```bash
systemctl is-active k3s || true
sudo ls /var/lib/rancher/k3s/server 2>/dev/null && echo "stale data present"
[ -x /usr/local/bin/k3s-uninstall.sh ] && sudo /usr/local/bin/k3s-uninstall.sh || echo "no uninstaller; removing manually"
[ -d /var/lib/rancher/k3s ] && sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s || true
```

Expected: `/var/lib/rancher/k3s` gone; k3s binary may be gone too (Ansible reinstalls).

- [ ] **Step 3: Write k3s_server role**

`ansible/roles/k3s_server/templates/config.yaml.j2`:
```yaml
node-name: {{ inventory_hostname }}
tls-san:
  - {{ ansible_host }}
  - {{ inventory_hostname }}
write-kubeconfig-mode: "0600"
secrets-encryption: true
```

`ansible/roles/k3s_server/tasks/main.yml`:
```yaml
- name: k3s config dir
  ansible.builtin.file: { path: /etc/rancher/k3s, state: directory, mode: "0755" }

- name: k3s server config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  register: k3s_cfg

- name: Download k3s installer
  ansible.builtin.get_url:
    url: https://get.k3s.io
    dest: /usr/local/share/k3s-install.sh
    mode: "0755"

- name: Install/upgrade k3s server (pinned)
  ansible.builtin.command: /usr/local/share/k3s-install.sh
  environment:
    INSTALL_K3S_VERSION: "{{ k3s_version }}"
  args:
    creates: /usr/local/bin/k3s
  register: k3s_install

- name: Restart k3s on config change
  ansible.builtin.systemd:
    name: k3s
    state: "{{ 'restarted' if (k3s_cfg.changed and not k3s_install.changed) else 'started' }}"
    enabled: true

- name: Wait for node Ready
  ansible.builtin.command: k3s kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=180s
  changed_when: false
```

- [ ] **Step 4: Write k3s_agent role (for future nodes; not executed now)**

`ansible/roles/k3s_agent/templates/config.yaml.j2`:
```yaml
node-name: {{ inventory_hostname }}
server: https://{{ hostvars[groups['server'][0]].ansible_host }}:6443
token: "{{ k3s_node_token }}"
```

`ansible/roles/k3s_agent/tasks/main.yml`:
```yaml
- name: Read join token from server
  ansible.builtin.slurp:
    src: /var/lib/rancher/k3s/server/node-token
  delegate_to: "{{ groups['server'][0] }}"
  register: node_token
  run_once: true

- name: k3s config dir
  ansible.builtin.file: { path: /etc/rancher/k3s, state: directory, mode: "0755" }

- name: k3s agent config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  vars:
    k3s_node_token: "{{ node_token.content | b64decode | trim }}"

- name: Download k3s installer
  ansible.builtin.get_url:
    url: https://get.k3s.io
    dest: /usr/local/share/k3s-install.sh
    mode: "0755"

- name: Install k3s agent (pinned)
  ansible.builtin.command: /usr/local/share/k3s-install.sh
  environment:
    INSTALL_K3S_VERSION: "{{ k3s_version }}"
    INSTALL_K3S_EXEC: agent
  args:
    creates: /usr/local/bin/k3s

- name: Ensure agent running
  ansible.builtin.systemd: { name: k3s-agent, state: started, enabled: true }
```

- [ ] **Step 5: Run and verify cluster**

```bash
cd ~/iac/ansible && ansible-playbook site.yml
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ducle:ducle ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes -o wide && kubectl -n kube-system get pods
```

Expected: node `algovn` `Ready`, version matches pin; `traefik-*`, `svclb-traefik-*`, `coredns`, `local-path-provisioner`, `metrics-server` pods Running/Completed. Re-run playbook → `changed=0`.

- [ ] **Step 6: Validate, commit, push**

```bash
cd ~/iac && scripts/validate.sh && git add -A && git commit -m "feat(ansible): k3s server+agent roles; algovn cluster up" && git push
```

---

### Task 5: Argo CD — slim install, bootstrap, self-management

**Files:**
- Create: `platform/argocd/kustomization.yaml`, `platform/argocd/patches/slim.yaml`, `platform/argocd/patches/params-cm.yaml`
- Create: `bootstrap/kustomization.yaml`, `bootstrap/root-app.yaml`
- Create: `clusters/algovn/platform/argocd.yaml`
- Delete: `clusters/algovn/platform/.gitkeep`

**Interfaces:**
- Consumes: running k3s (Task 4).
- Produces: Argo CD in ns `argocd` (server insecure=true, dex + notifications removed); root Application `root` recursing `clusters/algovn/`; pattern every later task follows: config under `platform/<x>/` or `apps/<x>/` + Application in `clusters/algovn/{platform,apps}/<x>.yaml`; `argocd` CLI logged in.

- [ ] **Step 1: Pin Argo CD version**

```bash
curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name
```

Expected like `v3.2.1` (example — use printed value everywhere `v3.2.1` appears below).

- [ ] **Step 2: Write slim kustomization**

`platform/argocd/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.1/manifests/install.yaml
patches:
  - path: patches/slim.yaml
  - path: patches/params-cm.yaml
```

`platform/argocd/patches/slim.yaml`:
```yaml
$patch: delete
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-dex-server
---
$patch: delete
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-notifications-controller
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: argocd-application-controller
spec:
  template:
    spec:
      containers:
        - name: argocd-application-controller
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 512Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
spec:
  template:
    spec:
      containers:
        - name: argocd-repo-server
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 384Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-server
spec:
  template:
    spec:
      containers:
        - name: argocd-server
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 256Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-redis
spec:
  template:
    spec:
      containers:
        - name: redis
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits: { memory: 128Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-applicationset-controller
spec:
  template:
    spec:
      containers:
        - name: argocd-applicationset-controller
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits: { memory: 192Mi }
```

`platform/argocd/patches/params-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  server.insecure: "true"
```

Note: if `kustomize build platform/argocd` fails on `$patch: delete` for a resource kind, verify the Deployment names above against `kubectl kustomize` output of the pinned install.yaml — names are stable across v3.x.

- [ ] **Step 3: Write bootstrap (root app-of-apps)**

`bootstrap/root-app.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: clusters/algovn
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`bootstrap/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../platform/argocd
  - root-app.yaml
```

- [ ] **Step 4: Write Argo's self-management Application**

`clusters/algovn/platform/argocd.yaml` (and `git rm clusters/algovn/platform/.gitkeep`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

- [ ] **Step 5: Validate + push FIRST (Argo pulls from GitHub), then bootstrap**

```bash
cd ~/iac && scripts/validate.sh
git add -A && git commit -m "feat(argocd): slim install, bootstrap, root app-of-apps, self-management" && git push
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k bootstrap/
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
```

Expected: all argocd pods Running; NO `argocd-dex-server` or `argocd-notifications-controller` pods exist.

- [ ] **Step 6: Install argocd CLI, login, verify self-management**

```bash
ARGO_VER=v3.2.1  # same pin as Step 1
sudo curl -sL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGO_VER}/argocd-linux-arm64" && sudo chmod +x /usr/local/bin/argocd
ARGO_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 &
sleep 3 && argocd login localhost:8080 --username admin --password "$ARGO_PW" --plaintext
argocd app list
```

Expected: apps `root` and `argocd` both reach `Synced` / `Healthy` within ~3 min (`argocd app wait root argocd --timeout 300`).

- [ ] **Step 7 [NEEDS USER]: Rotate admin password into password manager**

```bash
argocd account update-password --current-password "$ARGO_PW"   # user types new password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

User stores the new password in their password manager. (Spec §8 listed a sealed bcrypt hash for Argo admin; deliberate deviation: `argocd-secret` mixes operator-generated keys — sealing it wholesale breaks them. Password-manager storage + this rotation achieves the same "no plaintext in git, survivable rebuild". Recorded in `docs/runbooks/secrets.md`, Task 18.)

- [ ] **Step 8: GitOps loop proof + commit**

```bash
kubectl -n argocd delete configmap argocd-cmd-params-cm --wait=true && sleep 240
kubectl -n argocd get configmap argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'
```

Expected: `true` — Argo self-healed the deleted ConfigMap from git. Nothing to commit (Step 5 pushed); done.

---

### Task 6: Sealed Secrets + sealing workflow + key backup

**Files:**
- Create: `platform/sealed-secrets/values.yaml`, `clusters/algovn/platform/sealed-secrets.yaml`, `scripts/seal.sh`

**Interfaces:**
- Consumes: Argo pattern (Task 5).
- Produces: controller `sealed-secrets` in ns `sealed-secrets`; `scripts/seal.sh <namespace> < plain-secret.yaml > sealed.yaml`; sealing key backed up. All later secret steps use `seal.sh`.

- [ ] **Step 1: Pin chart + write values**

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update sealed-secrets
helm search repo sealed-secrets/sealed-secrets --versions | head -3
```

`platform/sealed-secrets/values.yaml` (chart version example `2.17.4` — use printed):
```yaml
fullnameOverride: sealed-secrets
resources:
  requests: { cpu: 25m, memory: 64Mi }
  limits: { memory: 128Mi }
```

- [ ] **Step 2: Write Application (multi-source: chart + values-from-git)**

`clusters/algovn/platform/sealed-secrets.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
spec:
  project: default
  sources:
    - repoURL: https://bitnami-labs.github.io/sealed-secrets
      chart: sealed-secrets
      targetRevision: 2.17.4
      helm:
        releaseName: sealed-secrets
        valueFiles:
          - $values/platform/sealed-secrets/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: sealed-secrets
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 3: Install kubeseal CLI + write seal.sh**

```bash
KS_VER=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS_VER}/kubeseal-${KS_VER}-linux-arm64.tar.gz" | sudo tar xz -C /usr/local/bin kubeseal
kubeseal --version
```

`scripts/seal.sh`:
```bash
#!/usr/bin/env bash
# Usage: kubectl create secret generic NAME -n NS --from-... --dry-run=client -o yaml | scripts/seal.sh
set -euo pipefail
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml
```

```bash
chmod +x scripts/seal.sh
```

- [ ] **Step 4: Deploy via GitOps, verify round-trip**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): sealed-secrets controller + seal.sh" && git push
argocd app wait sealed-secrets --timeout 300
kubectl create secret generic smoke -n default --from-literal=hello=world --dry-run=client -o yaml | scripts/seal.sh | kubectl apply -f -
sleep 5 && kubectl get secret smoke -n default -o jsonpath='{.data.hello}' | base64 -d && kubectl delete sealedsecret smoke -n default
```

Expected: prints `world`, then cleanup.

- [ ] **Step 5 [NEEDS USER]: Back up sealing key to password manager**

```bash
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/.secrets/sealed-secrets-key.yaml
chmod 600 ~/.secrets/sealed-secrets-key.yaml && echo "SAVE THE FILE CONTENT IN YOUR PASSWORD MANAGER NOW (secure note: 'algovn sealed-secrets key')"
```

After the user confirms it's stored: `shred -u ~/.secrets/sealed-secrets-key.yaml`. **Do not proceed to Task 7 until confirmed** — every sealed secret from here depends on this backup.

---

### Task 7: Traefik tuning (k3s built-in) via GitOps

**Files:**
- Create: `platform/traefik/helmchartconfig.yaml`, `platform/traefik/tlsstore.yaml`, `platform/traefik/kustomization.yaml`
- Create: `clusters/algovn/platform/traefik-config.yaml`

**Interfaces:**
- Consumes: k3s built-in Traefik (kube-system), Argo pattern.
- Produces: Traefik with Prometheus metrics + resource limits; `TLSStore default` (kube-system) expecting secret `wildcard-algovn-tls` (issued Task 8). LAN entry: node IP :80/:443 via svclb.

- [ ] **Step 1: Write manifests**

`platform/traefik/helmchartconfig.yaml`:
```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    metrics:
      prometheus:
        entryPoint: metrics
    globalArguments:
      - "--global.checknewversion=false"
      - "--global.sendanonymoususage=false"
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { memory: 160Mi }
```

`platform/traefik/tlsstore.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system
spec:
  defaultCertificate:
    secretName: wildcard-algovn-tls
```

`platform/traefik/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmchartconfig.yaml
  - tlsstore.yaml
```

`clusters/algovn/platform/traefik-config.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/traefik
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 2: Deploy + verify**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): traefik metrics/limits + default TLSStore" && git push
argocd app wait traefik-config --timeout 300
kubectl -n kube-system rollout status deploy/traefik --timeout=180s
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.102.202/
```

Expected: app Synced/Healthy (TLSStore shows synced even though its secret doesn't exist yet — Traefik serves self-signed until Task 8); curl prints `404` (Traefik default backend over TLS).

---

### Task 8: cert-manager + wildcard LAN TLS `[NEEDS USER]`

**Files:**
- Create: `platform/cert-manager/values.yaml`, `platform/cert-manager/manifests/kustomization.yaml`, `platform/cert-manager/manifests/cloudflare-token-sealed.yaml`, `platform/cert-manager/manifests/clusterissuer.yaml`, `platform/cert-manager/manifests/wildcard-cert.yaml`
- Create: `clusters/algovn/platform/cert-manager.yaml`, `clusters/algovn/platform/cert-manager-config.yaml`

**Interfaces:**
- Consumes: `seal.sh` (Task 6), `TLSStore` (Task 7).
- Produces: `ClusterIssuer letsencrypt-dns`; secret `wildcard-algovn-tls` (kube-system) → Traefik default cert for `*.algovn.com`; sealed `cloudflare-api-token` pattern reused in Task 10; user's CF token in `~/.secrets/cf-token` until Task 10 finishes.

- [ ] **Step 1 [NEEDS USER]: Create Cloudflare API token**

User: Cloudflare dashboard → My Profile → API Tokens → Create Token → template "Edit zone DNS" → Zone Resources: Include → Specific zone → `algovn.com` → Continue → Create. Paste the token when prompted; store it:

```bash
read -rs CF_TOKEN && printf '%s' "$CF_TOKEN" > ~/.secrets/cf-token && chmod 600 ~/.secrets/cf-token
curl -s -H "Authorization: Bearer $(cat ~/.secrets/cf-token)" https://api.cloudflare.com/client/v4/user/tokens/verify | jq .success
```

Expected: `true`.

- [ ] **Step 2: Seal token for cert-manager namespace**

```bash
kubectl create secret generic cloudflare-api-token -n cert-manager --from-file=token="$HOME/.secrets/cf-token" --dry-run=client -o yaml \
  | scripts/seal.sh > platform/cert-manager/manifests/cloudflare-token-sealed.yaml
grep -c 'kind: SealedSecret' platform/cert-manager/manifests/cloudflare-token-sealed.yaml
```

Expected: `1`. (kubeseal encrypts for namespace `cert-manager` even though it doesn't exist yet — fine.)

- [ ] **Step 3: Write chart values + Applications + issuer/cert**

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update jetstack && helm search repo jetstack/cert-manager --versions | head -3
```

`platform/cert-manager/values.yaml` (version example `v1.18.2` — use printed):
```yaml
crds:
  enabled: true
resources:
  requests: { cpu: 25m, memory: 64Mi }
  limits: { memory: 128Mi }
webhook:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits: { memory: 64Mi }
cainjector:
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits: { memory: 128Mi }
```

`clusters/algovn/platform/cert-manager.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-4"
spec:
  project: default
  sources:
    - repoURL: https://charts.jetstack.io
      chart: cert-manager
      targetRevision: v1.18.2
      helm:
        releaseName: cert-manager
        valueFiles:
          - $values/platform/cert-manager/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

`platform/cert-manager/manifests/clusterissuer.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: minhducle.dev@gmail.com
    privateKeySecretRef:
      name: letsencrypt-dns-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: token
```

`platform/cert-manager/manifests/wildcard-cert.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-algovn
  namespace: kube-system
spec:
  secretName: wildcard-algovn-tls
  issuerRef: { name: letsencrypt-dns, kind: ClusterIssuer }
  dnsNames: ["algovn.com", "*.algovn.com"]
```

`platform/cert-manager/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cloudflare-token-sealed.yaml
  - clusterissuer.yaml
  - wildcard-cert.yaml
```

`clusters/algovn/platform/cert-manager-config.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/cert-manager/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry:
      limit: 5
      backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

Note: dns01 solver needs no inbound connectivity — works behind CGNAT. `wildcard-cert.yaml` targets namespace `kube-system` explicitly (metadata wins over Application destination).

- [ ] **Step 4: Deploy + verify real TLS on LAN**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): cert-manager, letsencrypt dns01, wildcard cert" && git push
argocd app wait cert-manager cert-manager-config --timeout 600
kubectl -n kube-system wait certificate/wildcard-algovn --for=condition=Ready --timeout=300s
curl -sv --resolve test.algovn.com:443:192.168.102.202 https://test.algovn.com/ 2>&1 | grep -E 'subject:|issuer:'
```

Expected: Certificate `Ready`; curl shows `subject: CN=algovn.com` (SAN `*.algovn.com`) and `issuer: ... Let's Encrypt` — real cert on LAN, no `-k` needed.

---

### Task 9: Cloudflare Tunnel (cloudflared) `[NEEDS USER]`

**Files:**
- Create: `platform/cloudflared/configmap.yaml`, `platform/cloudflared/deployment.yaml`, `platform/cloudflared/tunnel-credentials-sealed.yaml`, `platform/cloudflared/kustomization.yaml`
- Create: `clusters/algovn/platform/cloudflared.yaml`

**Interfaces:**
- Consumes: Traefik service (`traefik.kube-system.svc.cluster.local:80`), `seal.sh`.
- Produces: connected tunnel named `algovn`; **TUNNEL_ID** (record it — Task 10 needs `<TUNNEL_ID>.cfargotunnel.com`); account cert at `~/.cloudflared/cert.pem` (stays on Pi, mode 600).

- [ ] **Step 1: Install cloudflared binary (arm64)**

```bash
sudo curl -sL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" && sudo chmod +x /usr/local/bin/cloudflared
cloudflared --version
```

Record the printed version `2026.x.y` — used as the image tag in Step 3.

- [ ] **Step 2 [NEEDS USER]: Tunnel login + create**

```bash
cloudflared tunnel login
```

This prints a `https://dash.cloudflare.com/argotunnel?...` URL — user opens it in any browser, picks zone `algovn.com`, authorizes. Then:

```bash
chmod 600 ~/.cloudflared/cert.pem
cloudflared tunnel create algovn
TUNNEL_ID=$(cloudflared tunnel list --output json | jq -r '.[] | select(.name=="algovn").id') && echo "TUNNEL_ID=$TUNNEL_ID"
```

Expected: `Created tunnel algovn with id <uuid>`. **Record TUNNEL_ID.**

- [ ] **Step 3: Seal credentials, write manifests**

```bash
kubectl create secret generic tunnel-credentials -n cloudflared --from-file=credentials.json="$HOME/.cloudflared/${TUNNEL_ID}.json" --dry-run=client -o yaml \
  | scripts/seal.sh > platform/cloudflared/tunnel-credentials-sealed.yaml
shred -u ~/.cloudflared/${TUNNEL_ID}.json
```

`platform/cloudflared/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: algovn
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
    ingress:
      - hostname: "*.algovn.com"
        service: http://traefik.kube-system.svc.cluster.local:80
      - service: http_status:404
```

`platform/cloudflared/deployment.yaml` (image tag = Step 1 version):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
spec:
  replicas: 1
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
        - name: cloudflared
          image: docker.io/cloudflare/cloudflared:2026.6.1
          args: [tunnel, --config, /etc/cloudflared/config/config.yaml, run]
          livenessProbe:
            httpGet: { path: /ready, port: 2000 }
            initialDelaySeconds: 10
          resources:
            requests: { cpu: 25m, memory: 48Mi }
            limits: { memory: 128Mi }
          volumeMounts:
            - { name: config, mountPath: /etc/cloudflared/config, readOnly: true }
            - { name: creds, mountPath: /etc/cloudflared/creds, readOnly: true }
      volumes:
        - name: config
          configMap: { name: cloudflared-config }
        - name: creds
          secret: { secretName: tunnel-credentials }
```

`platform/cloudflared/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - tunnel-credentials-sealed.yaml
  - configmap.yaml
  - deployment.yaml
```

`clusters/algovn/platform/cloudflared.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflared
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/cloudflared
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflared
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 4: Deploy + verify tunnel connectivity**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): cloudflared tunnel (algovn), sealed credentials" && git push
argocd app wait cloudflared --timeout 300
kubectl -n cloudflared logs deploy/cloudflared | grep -i 'Registered tunnel connection' | head -2
cloudflared tunnel info algovn
```

Expected: ≥1 `Registered tunnel connection`; `tunnel info` shows an active connector.

---

### Task 10: external-dns → automatic public DNS

**Files:**
- Create: `platform/external-dns/values.yaml`, `platform/external-dns/manifests/kustomization.yaml`, `platform/external-dns/manifests/cloudflare-token-sealed.yaml`
- Create: `clusters/algovn/platform/external-dns.yaml`

**Interfaces:**
- Consumes: `~/.secrets/cf-token` (Task 8), TUNNEL_ID (Task 9).
- Produces: any Ingress host under `algovn.com` gets a proxied CNAME → `<TUNNEL_ID>.cfargotunnel.com` automatically. End of `~/.secrets/cf-token` lifecycle (shredded).

- [ ] **Step 1: Seal token for external-dns namespace**

```bash
kubectl create secret generic cloudflare-api-token -n external-dns --from-file=token="$HOME/.secrets/cf-token" --dry-run=client -o yaml \
  | scripts/seal.sh > platform/external-dns/manifests/cloudflare-token-sealed.yaml
shred -u ~/.secrets/cf-token
```

`platform/external-dns/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cloudflare-token-sealed.yaml
```

- [ ] **Step 2: Write values + Application (substitute real TUNNEL_ID)**

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ && helm repo update external-dns && helm search repo external-dns/external-dns --versions | head -3
```

`platform/external-dns/values.yaml` (chart example `1.19.0` — use printed; replace `<TUNNEL_ID>` with the Task 9 uuid):
```yaml
provider:
  name: cloudflare
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef: { name: cloudflare-api-token, key: token }
sources: [ingress]
domainFilters: [algovn.com]
policy: sync
txtOwnerId: algovn
extraArgs:
  - --cloudflare-proxied
  - --default-targets=<TUNNEL_ID>.cfargotunnel.com
resources:
  requests: { cpu: 10m, memory: 48Mi }
  limits: { memory: 96Mi }
```

`clusters/algovn/platform/external-dns.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-dns
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  sources:
    - repoURL: https://kubernetes-sigs.github.io/external-dns/
      chart: external-dns
      targetRevision: 1.19.0
      helm:
        releaseName: external-dns
        valueFiles:
          - $values/platform/external-dns/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      path: platform/external-dns/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: external-dns
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 3: Deploy**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): external-dns -> cloudflare, default target tunnel" && git push
argocd app wait external-dns --timeout 300
kubectl -n external-dns logs deploy/external-dns | tail -5
```

Expected: logs show `All records are already up to date` or record creation lines, no auth errors.

- [ ] **Step 4: E2E proof — throwaway public Ingress**

```bash
kubectl create ingress e2e-test -n default --rule="e2e-test.algovn.com/*=kubernetes:443" --class=traefik
sleep 90
dig +short CNAME e2e-test.algovn.com @1.1.1.1 ; dig +short A e2e-test.algovn.com @1.1.1.1 | head -2
curl -s -o /dev/null -w '%{http_code}\n' https://e2e-test.algovn.com/
kubectl delete ingress e2e-test -n default && sleep 90
dig +short A e2e-test.algovn.com @1.1.1.1
```

Expected: A records resolve (Cloudflare proxied — CNAME may be flattened); curl returns an HTTP status (any of 400/403/404 proves edge→tunnel→Traefik path); after delete, name stops resolving (policy sync prunes). **This is the internet-facing milestone.**

---

### Task 11: Monitoring — VictoriaMetrics stack + Grafana `[NEEDS USER]`

**Files:**
- Create: `platform/monitoring/values.yaml`, `platform/monitoring/manifests/kustomization.yaml`, `platform/monitoring/manifests/grafana-admin-sealed.yaml`, `platform/monitoring/manifests/grafana-ingress.yaml`, `platform/monitoring/manifests/scrapes.yaml`
- Create: `clusters/algovn/platform/monitoring.yaml`, `clusters/algovn/platform/monitoring-config.yaml`

**Interfaces:**
- Consumes: seal.sh; Traefik metrics (Task 7); external-dns (Task 10) auto-publishes `grafana.algovn.com`.
- Produces: ns `monitoring`: VMSingle (15d), VMAgent, Grafana at `https://grafana.algovn.com` (secret `grafana-admin`), VMAlert+Alertmanager shells (rules/receivers in Task 12). Datasource name `VictoriaMetrics`. CRDs `VMServiceScrape`/`VMRule` available.

- [ ] **Step 1 [NEEDS USER]: Grafana admin secret**

User provides a strong password (goes in password manager too):

```bash
read -rs GRAFANA_PW
kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_PW" --dry-run=client -o yaml \
  | scripts/seal.sh > platform/monitoring/manifests/grafana-admin-sealed.yaml && unset GRAFANA_PW
```

- [ ] **Step 2: Write stack values**

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/ && helm repo update vm && helm search repo vm/victoria-metrics-k8s-stack --versions | head -3
```

`platform/monitoring/values.yaml` (chart example `0.61.0` — use printed):
```yaml
fullnameOverride: vm
vmsingle:
  spec:
    retentionPeriod: 15d
    storage:
      accessModes: [ReadWriteOnce]
      resources: { requests: { storage: 20Gi } }
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits: { memory: 512Mi }
vmagent:
  spec:
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits: { memory: 256Mi }
vmalert:
  spec:
    resources:
      requests: { cpu: 25m, memory: 64Mi }
      limits: { memory: 128Mi }
alertmanager:
  enabled: true
  spec:
    configSecret: alertmanager-config
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits: { memory: 64Mi }
grafana:
  enabled: true
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  grafana.ini:
    server:
      root_url: https://grafana.algovn.com
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 256Mi }
  persistence: { enabled: false }
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeProxy: { enabled: false }
kubeEtcd: { enabled: false }
defaultDashboards:
  enabled: true
```

(k3s runs a single binary — controller-manager/scheduler/proxy/etcd scrape targets don't exist; disabling kills dead-target alerts. Grafana persistence off: dashboards are provisioned, config is git.)

- [ ] **Step 3: Grafana ingress + extra scrapes**

`platform/monitoring/manifests/grafana-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: traefik
  rules:
    - host: grafana.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vm-grafana
                port: { number: 80 }
  tls:
    - hosts: [grafana.algovn.com]
```

`platform/monitoring/manifests/scrapes.yaml`:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: argocd-metrics
  namespace: monitoring
spec:
  namespaceSelector: { match: [argocd] }
  selector:
    matchExpressions:
      - { key: app.kubernetes.io/name, operator: In, values: [argocd-metrics, argocd-server-metrics, argocd-repo-server] }
  endpoints:
    - port: metrics
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cert-manager
  namespace: monitoring
spec:
  namespaceSelector: { match: [cert-manager] }
  selector:
    matchLabels: { app.kubernetes.io/name: cert-manager }
  endpoints:
    - port: tcp-prometheus-servicemonitor
```

`platform/monitoring/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana-admin-sealed.yaml
  - grafana-ingress.yaml
  - scrapes.yaml
```

- [ ] **Step 4: Applications (stack wave -1, config wave 0)**

`clusters/algovn/platform/monitoring.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  sources:
    - repoURL: https://victoriametrics.github.io/helm-charts/
      chart: victoria-metrics-k8s-stack
      targetRevision: 0.61.0
      helm:
        releaseName: vm
        valueFiles:
          - $values/platform/monitoring/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

`clusters/algovn/platform/monitoring-config.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/monitoring/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry:
      limit: 5
      backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

- [ ] **Step 5: Deploy + verify (Alertmanager pends until Task 12 — expected)**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): victoria-metrics stack + grafana via tunnel" && git push
argocd app wait monitoring monitoring-config --timeout 900 || true
kubectl -n monitoring get pods
curl -s -o /dev/null -w '%{http_code}\n' https://grafana.algovn.com/login
free -h | head -2
```

Expected: vmsingle/vmagent/grafana/operator/kube-state-metrics/node-exporter Running (alertmanager may be Pending/CrashLoop until its `alertmanager-config` secret exists in Task 12 — acceptable); Grafana login page returns `200` **through the tunnel**; note free RAM for the budget log. Login at https://grafana.algovn.com with admin/<password> → Dashboards → Kubernetes views show live data.

---

### Task 12: Alerting — rules + Alertmanager → Telegram `[NEEDS USER]`

**Files:**
- Create: `platform/monitoring/manifests/alertmanager-config-sealed.yaml`, `platform/monitoring/manifests/vmrules.yaml`
- Modify: `platform/monitoring/manifests/kustomization.yaml`

**Interfaces:**
- Consumes: Task 11 stack (`configSecret: alertmanager-config` already referenced).
- Produces: firing alerts reach the user's Telegram; custom rules `ArgoAppNotSynced`, `ArgoAppUnhealthy`, `CertExpiringSoon` (bundled node/k8s rules cover node-down, disk, crashloop).

- [ ] **Step 1 [NEEDS USER]: Telegram bot**

User: in Telegram, talk to `@BotFather` → `/newbot` → name `algovn-alerts` → copy the bot token. Then message the new bot once (any text), and:

```bash
read -rs TG_TOKEN
curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" | jq '.result[0].message.chat.id'
```

Expected: a numeric chat id. Record as TG_CHAT_ID.

- [ ] **Step 2: Seal full Alertmanager config**

```bash
read -r TG_CHAT_ID   # paste the numeric chat id printed in Step 1
cat > ~/.secrets/alertmanager.yaml <<EOF
route:
  receiver: telegram
  group_by: [alertname, namespace]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
receivers:
  - name: telegram
    telegram_configs:
      - bot_token: ${TG_TOKEN}
        chat_id: ${TG_CHAT_ID}
        parse_mode: HTML
EOF
kubectl create secret generic alertmanager-config -n monitoring --from-file=alertmanager.yaml="$HOME/.secrets/alertmanager.yaml" --dry-run=client -o yaml \
  | scripts/seal.sh > platform/monitoring/manifests/alertmanager-config-sealed.yaml
shred -u ~/.secrets/alertmanager.yaml && unset TG_TOKEN
```

- [ ] **Step 3: Write custom VMRules**

`platform/monitoring/manifests/vmrules.yaml`:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: platform-custom
  namespace: monitoring
spec:
  groups:
    - name: gitops
      rules:
        - alert: ArgoAppNotSynced
          expr: argocd_app_info{sync_status!="Synced"} == 1
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: 'Argo app {{ $labels.name }} not synced for 15m'
        - alert: ArgoAppUnhealthy
          expr: argocd_app_info{health_status!~"Healthy|Progressing"} == 1
          for: 15m
          labels: { severity: critical }
          annotations:
            summary: 'Argo app {{ $labels.name }} unhealthy: {{ $labels.health_status }}'
    - name: certificates
      rules:
        - alert: CertExpiringSoon
          expr: certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600
          for: 1h
          labels: { severity: warning }
          annotations:
            summary: 'Certificate {{ $labels.name }} expires in under 14 days'
```

Add both files to `platform/monitoring/manifests/kustomization.yaml` resources:
```yaml
  - alertmanager-config-sealed.yaml
  - vmrules.yaml
```

- [ ] **Step 4: Deploy + fire a test alert**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(monitoring): telegram alerting + gitops/cert rules" && git push
argocd app wait monitoring monitoring-config --timeout 600
kubectl -n monitoring get pods | grep alertmanager
kubectl -n monitoring port-forward svc/vmalertmanager-vm 9093:9093 >/dev/null 2>&1 &
sleep 3 && curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{"labels":{"alertname":"PlanVerifyTest","severity":"info"},"annotations":{"summary":"Task 12 test alert - ignore"}}]' -w '%{http_code}\n'
```

Expected: alertmanager pod Running; POST returns `200`; **user confirms the Telegram message arrived** (~30s). If the Alertmanager service name differs, find it: `kubectl -n monitoring get svc | grep alertmanager`.

---

### Task 13: Logging — Loki + Alloy

**Files:**
- Create: `platform/logging/loki-values.yaml`, `platform/logging/alloy-values.yaml`
- Create: `clusters/algovn/platform/logging.yaml`

**Interfaces:**
- Consumes: Grafana (Task 11) for querying; local-path StorageClass.
- Produces: Loki push API `http://loki.logging.svc.cluster.local:3100/loki/api/v1/push`; Grafana datasource `Loki`; 7-day retention.

- [ ] **Step 1: Pin charts, write Loki values (RAM-critical flags)**

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
helm search repo grafana/loki --versions | head -3 && helm search repo grafana/alloy --versions | head -3
```

`platform/logging/loki-values.yaml` (chart example `6.30.0` — use printed):
```yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig: { replication_factor: 1 }
  storage: { type: filesystem }
  schemaConfig:
    configs:
      - from: "2026-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index: { prefix: index_, period: 24h }
  limits_config:
    retention_period: 168h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence: { enabled: true, size: 30Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
read: { replicas: 0 }
write: { replicas: 0 }
backend: { replicas: 0 }
gateway: { enabled: false }
chunksCache: { enabled: false }
resultsCache: { enabled: false }
lokiCanary: { enabled: false }
test: { enabled: false }
monitoring:
  selfMonitoring: { enabled: false, grafanaAgent: { installOperator: false } }
```

(`chunksCache`/`resultsCache` disabled is non-negotiable — default memcached would eat ~1GB.)

- [ ] **Step 2: Alloy values (container + journal logs → Loki)**

`platform/logging/alloy-values.yaml`:
```yaml
alloy:
  configMap:
    content: |
      discovery.kubernetes "pods" { role = "pod" }
      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
      }
      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }
      loki.source.journal "journal" {
        max_age    = "12h"
        labels     = { job = "systemd-journal" }
        forward_to = [loki.write.default.receiver]
      }
      loki.write "default" {
        endpoint { url = "http://loki.logging.svc.cluster.local:3100/loki/api/v1/push" }
      }
  mounts: { extra: [{ name: journal, mountPath: /var/log/journal, readOnly: true }] }
  resources:
    requests: { cpu: 50m, memory: 96Mi }
    limits: { memory: 192Mi }
controller:
  type: daemonset
  volumes:
    extra:
      - name: journal
        hostPath: { path: /var/log/journal }
```

- [ ] **Step 3: One Application, two chart sources**

`clusters/algovn/platform/logging.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 6.30.0
      helm:
        releaseName: loki
        valueFiles:
          - $values/platform/logging/loki-values.yaml
    - repoURL: https://grafana.github.io/helm-charts
      chart: alloy
      targetRevision: 1.2.0
      helm:
        releaseName: alloy
        valueFiles:
          - $values/platform/logging/alloy-values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Also add the Loki datasource to Grafana — append to `platform/monitoring/values.yaml` under `grafana:`:
```yaml
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.logging.svc.cluster.local:3100
      access: proxy
```

- [ ] **Step 4: Deploy + verify logs flow**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): loki + alloy logging, grafana datasource" && git push
argocd app wait logging monitoring --timeout 600
kubectl -n logging get pods
sleep 60 && curl -sG http://$(kubectl -n logging get svc loki -o jsonpath='{.spec.clusterIP}'):3100/loki/api/v1/query_range --data-urlencode 'query={namespace="argocd"}' --data-urlencode 'limit=3' | jq '.data.result | length'
```

Expected: `loki-0` + `alloy-*` Running; query returns > 0 streams. In Grafana → Explore → Loki: `{namespace="argocd"}` shows lines.

---

### Task 14: argocd-image-updater + app CI/CD template

**Files:**
- Create: `platform/image-updater/values.yaml`, `clusters/algovn/platform/image-updater.yaml`
- Create: `templates/github-actions-build-push.yaml`, `templates/README.md`

**Interfaces:**
- Consumes: Argo CD (Task 5).
- Produces: image-updater deployed (idle); copy-paste workflow building `ghcr.io/the-algovn/<app>` for arm64; documented onboarding (used when gn3 / just-an-counter migrate).

- [ ] **Step 1: Deploy image-updater**

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update argo && helm search repo argo/argocd-image-updater --versions | head -3
```

`platform/image-updater/values.yaml` (chart example `0.12.3` — use printed):
```yaml
fullnameOverride: argocd-image-updater
config:
  registries:
    - name: GitHub Container Registry
      prefix: ghcr.io
      api_url: https://ghcr.io
      default: true
resources:
  requests: { cpu: 10m, memory: 48Mi }
  limits: { memory: 96Mi }
```

`clusters/algovn/platform/image-updater.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: image-updater
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argocd-image-updater
      targetRevision: 0.12.3
      helm:
        releaseName: argocd-image-updater
        valueFiles:
          - $values/platform/image-updater/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 2: Write the reusable app workflow**

`templates/github-actions-build-push.yaml`:
```yaml
# Copy to <app-repo>/.github/workflows/build.yaml — builds linux/arm64 image to GHCR.
# Tags: vX.Y.Z git tags -> semver image tags; every push to main -> sha-<short> tag.
name: build
on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=semver,pattern={{version}}
            type=sha,prefix=sha-
      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

- [ ] **Step 3: Write onboarding doc**

`templates/README.md`:
```markdown
# Onboarding an app to the cluster (push-to-deploy)

1. **App repo**: copy `github-actions-build-push.yaml` to `.github/workflows/build.yaml`.
   Ensure a `Dockerfile` exists. Push a `vX.Y.Z` tag → image at `ghcr.io/<org>/<repo>`.
2. **Make the GHCR package public** (repo → Packages → settings) or seal a pull secret.
3. **This repo**: create `apps/<name>/` (Deployment/Service/Ingress + kustomization —
   copy `apps/homepage/` as the model) and `clusters/algovn/apps/<name>.yaml`
   Application. Host `<name>.algovn.com` gets DNS + tunnel automatically.
4. **Auto-update on new images**: add to the Application `metadata.annotations`:
       argocd-image-updater.argoproj.io/image-list: app=ghcr.io/<org>/<repo>
       argocd-image-updater.argoproj.io/app.update-strategy: semver
       argocd-image-updater.argoproj.io/write-back-method: git
   One-time (first app only): give image-updater push access — create a GitHub
   fine-grained PAT (this repo, Contents RW), then:
       kubectl create secret generic git-creds -n argocd \
         --from-literal=username=mduclehcm --from-literal=password=<PAT> \
         --dry-run=client -o yaml | scripts/seal.sh > platform/image-updater/git-creds-sealed.yaml
   Add it to a kustomization synced by the image-updater Application, and set
   `config.gitCredentials` in `platform/image-updater/values.yaml` per chart docs.
5. Merge. `argocd app wait <name>` → live at `https://<name>.algovn.com`.
```

- [ ] **Step 4: Deploy + verify**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(platform): image-updater + app ci/cd template" && git push
argocd app wait image-updater --timeout 300
kubectl -n argocd logs deploy/argocd-image-updater --tail=5
actionlint templates/github-actions-build-push.yaml && echo "template lints clean"
```

Expected: pod Running, logs show startup without registry errors (idle — no annotated apps yet); actionlint clean.

---

### Task 15: Seed app — homepage

**Files:**
- Create: `apps/homepage/{namespace.yaml,rbac.yaml,configmap.yaml,deployment.yaml,service.yaml,ingress.yaml,kustomization.yaml}`
- Create: `clusters/algovn/apps/homepage.yaml`
- Delete: `clusters/algovn/apps/.gitkeep`

**Interfaces:**
- Consumes: full platform path (Ingress → external-dns → tunnel → Traefik).
- Produces: `https://homepage.algovn.com`; `apps/homepage/` is the copy-me model referenced by `templates/README.md`.

- [ ] **Step 1: Pin image**

```bash
curl -s https://api.github.com/repos/gethomepage/homepage/releases/latest | jq -r .tag_name
```

Example `v1.4.6` — use printed value in the Deployment image below.

- [ ] **Step 2: Write manifests**

`apps/homepage/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homepage
```

`apps/homepage/rbac.yaml` (read-only discovery of ingresses/services):
```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: homepage, namespace: homepage }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: homepage }
rules:
  - apiGroups: [""]
    resources: [namespaces, pods, nodes]
    verbs: [get, list]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [nodes, pods]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: homepage }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: homepage }
subjects: [{ kind: ServiceAccount, name: homepage, namespace: homepage }]
```

`apps/homepage/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homepage-config
  namespace: homepage
data:
  settings.yaml: |
    title: algovn
  kubernetes.yaml: |
    mode: cluster
  services.yaml: |
    - Platform:
        - Argo CD:
            href: https://argocd.algovn.com
            description: GitOps
        - Grafana:
            href: https://grafana.algovn.com
            description: Metrics + logs
        - Uptime Kuma:
            href: https://uptime.algovn.com
            description: Uptime monitoring
  widgets.yaml: |
    - resources:
        backend: kubernetes
        expanded: true
        cpu: true
        memory: true
  bookmarks.yaml: ""
  docker.yaml: ""
```

`apps/homepage/deployment.yaml` (image tag from Step 1):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: homepage
spec:
  replicas: 1
  selector:
    matchLabels: { app: homepage }
  template:
    metadata:
      labels: { app: homepage }
    spec:
      serviceAccountName: homepage
      containers:
        - name: homepage
          image: ghcr.io/gethomepage/homepage:v1.4.6
          ports: [{ containerPort: 3000 }]
          env:
            - { name: HOMEPAGE_ALLOWED_HOSTS, value: homepage.algovn.com }
          resources:
            requests: { cpu: 25m, memory: 96Mi }
            limits: { memory: 192Mi }
          volumeMounts:
            - { name: config, mountPath: /app/config }
      volumes:
        - name: config
          configMap: { name: homepage-config }
```

`apps/homepage/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: homepage
  namespace: homepage
spec:
  selector: { app: homepage }
  ports: [{ port: 80, targetPort: 3000 }]
```

`apps/homepage/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage
  namespace: homepage
spec:
  ingressClassName: traefik
  rules:
    - host: homepage.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homepage
                port: { number: 80 }
  tls:
    - hosts: [homepage.algovn.com]
```

`apps/homepage/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - rbac.yaml
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

`clusters/algovn/apps/homepage.yaml` (`git rm clusters/algovn/apps/.gitkeep`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homepage
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: apps/homepage
  destination:
    server: https://kubernetes.default.svc
    namespace: homepage
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 3: Deploy + verify public URL**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(apps): homepage dashboard" && git push
argocd app wait homepage --timeout 300
sleep 90 && curl -s -o /dev/null -w '%{http_code}\n' https://homepage.algovn.com/
```

Expected: `200` from the internet-facing URL. Spec §14's public-curl criterion met.

---

### Task 16: Seed app — uptime-kuma `[NEEDS USER]`

**Files:**
- Create: `apps/uptime-kuma/{namespace.yaml,statefulset.yaml,service.yaml,ingress.yaml,kustomization.yaml}`
- Create: `clusters/algovn/apps/uptime-kuma.yaml`

**Interfaces:**
- Consumes: platform path; local-path StorageClass.
- Produces: `https://uptime.algovn.com` with monitors watching the public endpoints (spec §14 "continuous verification").

- [ ] **Step 1: Write manifests**

Pin image: `curl -s https://api.github.com/repos/louislam/uptime-kuma/releases/latest | jq -r .tag_name` (example `1.23.16` — 1.x line; use printed).

`apps/uptime-kuma/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: uptime-kuma
```

`apps/uptime-kuma/statefulset.yaml`:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: uptime-kuma
  namespace: uptime-kuma
spec:
  serviceName: uptime-kuma
  replicas: 1
  selector:
    matchLabels: { app: uptime-kuma }
  template:
    metadata:
      labels: { app: uptime-kuma }
    spec:
      containers:
        - name: uptime-kuma
          image: docker.io/louislam/uptime-kuma:1.23.16
          ports: [{ containerPort: 3001 }]
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: data, mountPath: /app/data }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path
        resources: { requests: { storage: 2Gi } }
```

`apps/uptime-kuma/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: uptime-kuma
  namespace: uptime-kuma
spec:
  selector: { app: uptime-kuma }
  ports: [{ port: 80, targetPort: 3001 }]
```

`apps/uptime-kuma/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: uptime-kuma
  namespace: uptime-kuma
spec:
  ingressClassName: traefik
  rules:
    - host: uptime.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: uptime-kuma
                port: { number: 80 }
  tls:
    - hosts: [uptime.algovn.com]
```

`apps/uptime-kuma/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - statefulset.yaml
  - service.yaml
  - ingress.yaml
```

`clusters/algovn/apps/uptime-kuma.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: uptime-kuma
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: apps/uptime-kuma
  destination:
    server: https://kubernetes.default.svc
    namespace: uptime-kuma
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 2: Deploy + verify**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(apps): uptime-kuma" && git push
argocd app wait uptime-kuma --timeout 300
sleep 90 && curl -s -o /dev/null -w '%{http_code}\n' https://uptime.algovn.com/
```

Expected: `200` (setup wizard).

- [ ] **Step 3 [NEEDS USER]: Create admin + monitors**

User opens `https://uptime.algovn.com` → create admin account (password → password manager) → add HTTP(s) monitors (60s interval): `https://homepage.algovn.com`, `https://grafana.algovn.com/login`, `https://uptime.algovn.com`. Confirm all three go green.

---

### Task 17: Expose Argo CD UI + Cloudflare Access `[NEEDS USER]`

**Files:**
- Create: `platform/argocd/ingress.yaml`; Modify: `platform/argocd/kustomization.yaml`
- Create: `docs/runbooks/cloudflare-access.md`

**Interfaces:**
- Consumes: argocd server.insecure=true (Task 5), platform path.
- Produces: `https://argocd.algovn.com` behind CF Access; `grafana.algovn.com` behind CF Access; runbook to reproduce policies.

- [ ] **Step 1: Argo CD Ingress**

`platform/argocd/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
spec:
  ingressClassName: traefik
  rules:
    - host: argocd.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port: { number: 80 }
  tls:
    - hosts: [argocd.algovn.com]
```

Append `- ingress.yaml` to `platform/argocd/kustomization.yaml` resources.

```bash
scripts/validate.sh && git add -A && git commit -m "feat(argocd): expose UI via tunnel" && git push
argocd app wait argocd --timeout 300 && sleep 90
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.algovn.com/
```

Expected: `200` (Argo login page — NOT yet Access-protected).

- [ ] **Step 2 [NEEDS USER]: Cloudflare Access policies**

User, in Cloudflare dashboard (exact path): **Zero Trust → Access → Applications → Add an application → Self-hosted**:
- App 1: name `argocd`, domain `argocd.algovn.com`; policy `admin-only`: Action Allow, Include → Emails → `minhducle.dev@gmail.com`; identity: One-time PIN (default). Session duration 24h. Save.
- App 2: name `grafana`, domain `grafana.algovn.com`, same policy. Save.

- [ ] **Step 3: Verify the challenge + write runbook**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.algovn.com/
curl -s -o /dev/null -w '%{http_code}\n' https://grafana.algovn.com/login
```

Expected: both now return `302` (redirect to `<team>.cloudflareaccess.com` login) instead of `200`. User confirms browser login via email PIN works and lands in each UI.

`docs/runbooks/cloudflare-access.md` — write the Step 2 instructions verbatim as a numbered list, plus: "Re-check after any rebuild: policies live in Cloudflare, not in git. Current protected hosts: argocd.algovn.com, grafana.algovn.com. Owner email: minhducle.dev@gmail.com."

```bash
scripts/validate.sh && git add -A && git commit -m "docs: cloudflare access runbook" && git push
```

---

### Task 18: Runbooks

**Files:**
- Create: `docs/runbooks/bootstrap.md`, `docs/runbooks/rebuild.md`, `docs/runbooks/add-node.md`, `docs/runbooks/add-app.md`, `docs/runbooks/secrets.md`, `docs/runbooks/verify.md`

**Interfaces:**
- Consumes: everything built in Tasks 1–17.
- Produces: operational docs; `verify.md` is the acceptance checklist executed in Task 19.

- [ ] **Step 1: Write the six runbooks** (complete content below — adjust only if implementation diverged)

`docs/runbooks/bootstrap.md`:
```markdown
# Bootstrap (fresh cluster from this repo)
Pre-req: node provisioned (`ansible/`), kubeconfig at ~/.kube/config, kubeseal + argocd CLIs.
1. `kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -`
2. `kubectl apply -k bootstrap/`
3. RESTORE SEALING KEY (docs/runbooks/secrets.md §restore) — do this BEFORE waves need secrets.
4. `kubectl -n argocd rollout status deploy/argocd-server --timeout=300s`
5. Watch convergence: `argocd app list` until all Synced/Healthy (sealed-secrets first, waves -5→1).
6. Run docs/runbooks/verify.md.
```

`docs/runbooks/rebuild.md`:
```markdown
# Full rebuild (dead Pi / fresh OS) — target < 1 hour
Needs from password manager: sealed-secrets key, Argo admin pw, Grafana admin pw.
1. Flash Ubuntu Server (arm64), hostname algovn, static IP 192.168.102.202, user ducle.
2. Clone this repo to ~/iac. Install ansible: `sudo apt install -y ansible`.
3. `cd ~/iac/ansible && ansible-playbook site.yml`
4. kubeconfig: `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ducle: ~/.kube/config && chmod 600 ~/.kube/config`
5. Follow docs/runbooks/bootstrap.md (includes key restore).
6. cloudflared account cert is NOT in git: if ~/.cloudflared/cert.pem lost, `cloudflared tunnel login`
   again (tunnel + its sealed credentials in git stay valid; login only re-authorizes the CLI).
7. Re-check Cloudflare Access apps (docs/runbooks/cloudflare-access.md).
8. Accepted losses: metrics history, Loki logs, uptime-kuma history (recreate admin+monitors, Task 16 §3).
```

`docs/runbooks/add-node.md`:
```markdown
# Add a worker node
1. Flash Ubuntu Server arm64, user ducle, static IP, ssh key from algovn.
2. ansible/inventory.yml → under `agents.hosts`: `<name>: { ansible_host: <ip> }` (remove `{}`).
3. `cd ansible && ansible-playbook site.yml --limit <name>,algovn`
4. `kubectl get nodes` → new node Ready. Commit the inventory change.
HA servers (3+ nodes) = separate project: sqlite→etcd migration (spec §5).
```

`docs/runbooks/add-app.md`:
```markdown
# Add an app/service
See templates/README.md (full onboarding incl. CI + image automation).
Quick version (public image): copy apps/homepage/ → apps/<name>/, edit names/image/host,
add clusters/algovn/apps/<name>.yaml, `scripts/validate.sh`, push.
DNS + tunnel + TLS are automatic from the Ingress host. `argocd app wait <name>`.
```

`docs/runbooks/secrets.md`:
```markdown
# Secrets
## Seal a new secret
kubectl create secret generic NAME -n NS --from-literal=k=v --dry-run=client -o yaml | scripts/seal.sh > <dir>/name-sealed.yaml
Plaintext staging: ~/.secrets/ (chmod 700), `shred -u` after. NEVER commit plaintext (gitleaks enforces).
## Backup sealing key (after install or key rotation)
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/.secrets/key.yaml
→ password manager → `shred -u ~/.secrets/key.yaml`
## Restore sealing key (during bootstrap step 3)
Save the password-manager note to ~/.secrets/key.yaml, then:
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/.secrets/key.yaml && shred -u ~/.secrets/key.yaml
kubectl -n sealed-secrets delete pod -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
## Not sealed (password manager only)
Argo CD admin (argocd account update-password), Grafana admin (sealed grafana-admin secret holds it,
but keep a copy), uptime-kuma admin, Cloudflare account creds.
## Inventory of sealed secrets
cert-manager/cloudflare-api-token · external-dns/cloudflare-api-token · cloudflared/tunnel-credentials ·
monitoring/grafana-admin · monitoring/alertmanager-config
```

`docs/runbooks/verify.md`:
```markdown
# Verify (run after bootstrap, rebuild, or platform change)
1. `argocd app list` → every app Synced + Healthy.
2. `kubectl get nodes` → all Ready. `kubectl get pods -A | grep -Ev 'Running|Completed'` → empty.
3. Public path: `curl -s -o /dev/null -w '%{http_code}' https://homepage.algovn.com/` → 200.
4. Access: `curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/` → 302 (challenge).
5. LAN TLS: `curl -s --resolve x.algovn.com:443:192.168.102.202 https://x.algovn.com -o /dev/null -w '%{http_code}'` → 404, no cert error.
6. Grafana: dashboards show live node metrics; Explore→Loki `{namespace="argocd"}` returns lines.
7. Alert path: port-forward alertmanager :9093, POST test alert (Task 12 §4 command) → Telegram message.
8. Drift test: `kubectl -n homepage scale deploy homepage --replicas=3`; within ~5 min replicas back to 1.
9. `free -h` → available ≥ 1GB with no user workloads under load.
10. uptime-kuma monitors all green.
```

- [ ] **Step 2: Validate, commit, push**

```bash
scripts/validate.sh && git add -A && git commit -m "docs: operational runbooks" && git push
```

---

### Task 19: Steady-state — branch protection, Renovate, final acceptance `[NEEDS USER]`

**Files:**
- Modify: `README.md` (add verify badge/link)

**Interfaces:**
- Consumes: CI check `validate` (Task 2), `docs/runbooks/verify.md` (Task 18).
- Produces: protected `main` (PR + green CI required), Renovate active, acceptance evidence.

- [ ] **Step 1: Branch protection (PRs + green `validate` required)**

```bash
gh api -X PUT repos/the-algovn/iac/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["validate"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
gh api repos/the-algovn/iac/branches/main/protection --jq '.required_status_checks.contexts'
```

Expected: `["validate"]`. From now on changes go via PR; direct pushes are rejected. (`enforce_admins: false` keeps a documented owner escape hatch.)

- [ ] **Step 2 [NEEDS USER]: Enable Renovate**

User: https://github.com/apps/renovate → Install → select `the-algovn/iac` only. Then:

```bash
sleep 120 && gh pr list --repo the-algovn/iac
```

Expected: Renovate's "Configure Renovate" onboarding PR (or, since `renovate.json` exists, direct dependency PRs on Saturday schedule). Merge the onboarding PR if opened (via PR flow — CI must pass).

- [ ] **Step 3: Execute full acceptance checklist**

Run every line of `docs/runbooks/verify.md` and record outputs. All 10 items must pass — this is the spec §14 gate. Fix-forward any failures via PR before declaring done.

- [ ] **Step 4: Close out**

```bash
git checkout -b chore/readme-final && printf '\n## Status\nCluster live. Acceptance: docs/runbooks/verify.md — all green on %s.\n' "$(date -I 2>/dev/null || echo 2026-07-11)" >> README.md
git add README.md && git commit -m "docs: acceptance complete" && git push -u origin chore/readme-final
gh pr create --repo the-algovn/iac --fill && gh pr merge --auto --squash
```

Expected: PR merges once `validate` is green — proving the steady-state flow end-to-end.

---

## Spec coverage map (self-review)

| Spec section | Tasks |
|---|---|
| §3 layers + RAM budget | 3–5 (layers), limits in every task, budget check T11/T19 |
| §4 repo layout | 1, 5–16 |
| §5 Ansible | 3, 4 |
| §6 Argo app-of-apps, waves, self-manage | 5, waves in 6–16 |
| §7 tunnel, external-dns, Access, wildcard TLS | 7–10, 17 |
| §8 sealed secrets, key backup, gitleaks | 1, 2, 6, 8–12 (argocd-admin deviation documented T5§7, runbook `secrets.md`) |
| §9 VM/Grafana/Loki/alerts | 11, 12, 13 |
| §10 CI, Renovate, app template | 1, 2, 14, 19 |
| §11 seed apps | 15, 16 |
| §12 rebuild runbook | 18 |
| §13 deferred items | recorded in runbooks (add-node HA note, templates README image-updater creds) — nothing built (YAGNI) |
| §14 verification | 10§4 (E2E), 18 (`verify.md`), 19§3 (acceptance) |
| §15 out of scope | untouched |
