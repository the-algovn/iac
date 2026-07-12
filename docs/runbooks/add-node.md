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
HA servers (3+ nodes) = separate project: sqlite→etcd migration (spec §5).
