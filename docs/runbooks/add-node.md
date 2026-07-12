# Add a worker node
1. Ubuntu Server (amd64 or arm64), user ducle, static/reserved IP.
2. Prereqs: algovn's ssh key in the node's `authorized_keys`; passwordless sudo
   (`/etc/sudoers.d/ducle`: `ducle ALL=(ALL) NOPASSWD: ALL`, mode 0440).
3. Server firewall: algovn runs ufw (hand-managed, NOT in ansible) — must allow
   6443/tcp, 8472/udp, 10250/tcp from the node subnet (192.168.102.0/24 rules added
   2026-07-12). If blocked: agent hangs "activating", CA-cert timeouts in journal.
4. ansible/inventory.yml → under `agents.hosts`: `<name>: { ansible_host: <ip> }`.
5. On algovn: `cd ~/iac && git pull && cd ansible && ansible-playbook site.yml --limit <name>,algovn`
6. `kubectl get nodes` → new node Ready. Mixed-arch cluster: self-built images must be multi-arch.
7. Scheduling: the Pi carries taint `workload=pi:PreferNoSchedule` (in the ansible k3s
   server config), so workloads prefer worker nodes; the Pi keeps only the control plane
   and DaemonSets. k3s applies config-file taints ONLY at first registration — on an
   already-registered node apply it by hand:
   `kubectl taint node algovn workload=pi:PreferNoSchedule`
8. After a worker outage, pods that fell back to the Pi stay there. Nudge them home
   (DaemonSet pods just restart in place; everything else reschedules to workers):
   `for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do kubectl delete pods -n $ns --field-selector spec.nodeName=algovn --wait=false; done`
HA servers (3+ nodes) = separate project: sqlite→etcd migration (spec §5).
