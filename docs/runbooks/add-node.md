# Add a worker node
1. Flash Ubuntu Server arm64, user ducle, static IP, ssh key from algovn.
2. ansible/inventory.yml → under `agents.hosts`: `<name>: { ansible_host: <ip> }` (remove `{}`).
3. `cd ansible && ansible-playbook site.yml --limit <name>,algovn`
4. `kubectl get nodes` → new node Ready. Commit the inventory change.
HA servers (3+ nodes) = separate project: sqlite→etcd migration (spec §5).
