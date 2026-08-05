# Add a worker node
1. Clone VM from Proxmox template 9000 (`ubuntu-noble-tpl`, ciuser ducle — key +
   NOPASSWD sudo via cloud-init), static IP in the .110–.119 range, `--onboot 1`.
2. Node ufw first (hand-managed, NOT in ansible): allow 6443/tcp, 8472/udp, 10250/tcp,
   9100/tcp from 192.168.102.0/24, limit 22/tcp, allow 80,443/tcp, enable. The server
   VM (`algovn`, .111) already allows these. If blocked: agent hangs "activating",
   CA-cert timeouts in journal.
   ⚠️ 9100 is node_exporter. It is listed here as what a node *should* allow, not as
   what the existing nodes do: measured 2026-08-05, cp (.111) and w1 (.112) do NOT
   allow it, so `up{job="node-exporter"}` is `0` for both and their host metrics have
   never been collected — only w2 (.113) is scraped, by the vmagent that happens to
   run there. Fixing that means editing those nodes' firewalls by hand; see the
   "Known gap" note in docs/runbooks/stateful-vms.md.
3. ansible/inventory.yml → under `agents.hosts`: `<name>: { ansible_host: <ip> }`.
4. On the Mac: `cd ~/the-algovn/iac/ansible && ansible-playbook site.yml --limit <name>,algovn`
5. `kubectl get nodes` → new node Ready.
6. Scheduling: the server VM carries taint `workload=pi:PreferNoSchedule` (name is
   historical — kept because renaming is cosmetic churn; it lives in the ansible k3s
   server config), so workloads prefer worker nodes; the server keeps the control
   plane and DaemonSets. k3s applies config-file taints ONLY at first registration —
   on an already-registered node apply it by hand:
   `kubectl taint node algovn workload=pi:PreferNoSchedule`
7. After a worker outage, pods that fell back to the server VM stay there. Nudge them
   home (DaemonSet pods just restart in place; everything else reschedules to workers):
   `for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do kubectl delete pods -n $ns --field-selector spec.nodeName=algovn --wait=false; done`
HA servers (3+ nodes) = separate project: sqlite→etcd migration (spec §5).
New nodes skip the cloudflared remote-access play unless you define cloudflared_tunnel + cloudflared_ingress host vars (see docs/runbooks/remote-access.md).
