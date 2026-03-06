# Troubleshooting

Common issues encountered during setup and demo execution, with diagnostic steps and fixes.

---

## 1) Cluster B DNS resolves to wrong addresses

**Symptom:** Terraform times out creating Cluster B API key, or producer/consumer cannot connect to Cluster B.

**Diagnosis:**

```bash
python3 -c "import socket; print(socket.getaddrinfo('<cluster-b-bootstrap-hostname>', 443))"
```

- **Expected:** `10.0.2.x` (private endpoint subnet)
- **Problem:** `10.1.x.x` (Confluent internal CIDR, unreachable from outside)

> Do not trust `dig` output alone — it bypasses the system resolver and may show correct results while the system is actually using a different DNS path.

**Fixes:**

- Ensure the WireGuard tunnel is up: `sudo wg show`
- Ensure dnsmasq is running on the VM: `ssh ... "sudo systemctl status dnsmasq"`
- If dnsmasq failed to start (common after VM reboot without WireGuard), restart it: `ssh ... "sudo systemctl restart dnsmasq"`
- If a corporate VPN is injecting DNS resolvers that override WireGuard, disconnect it or set your primary network interface DNS manually to `10.200.0.1 8.8.8.8`

---

## 2) dnsmasq fails with "Cannot assign requested address"

**Cause:** dnsmasq tried to bind to `10.200.0.1` before WireGuard created the `wg0` interface.

**Fix:**

```bash
ssh -i demo_vm_key azureuser@<vm-ip>
sudo systemctl restart wg-quick@wg0
sudo systemctl restart dnsmasq
```

---

## 3) Promote script exits: "Mirror lag is not 0"

**Cause:** Producer on Cluster A is still writing. The mirror cannot drain to lag 0 while new messages arrive.

**Fix:**

1. Stop the producer on Cluster A (`Ctrl+C`).
2. Wait a few seconds for the mirror to catch up.
3. Re-run `~/promote-to-b.sh`.

---

## 4) Promote gets stuck in PENDING_STOPPED

**Cause:** Consumer group is active on the destination cluster (Cluster B) during promotion.

**Fix:**

1. Stop the consumer on Cluster B (`Ctrl+C`).
2. Re-run `~/promote-to-b.sh`.
3. Restart the consumer after the topic reaches `STOPPED`.

**Warning:** Never delete the cluster link while a topic is in `PENDING_STOPPED` — this can make the mirror topic on Cluster B irrecoverable.

---

## 5) Terraform apply hangs on confluent_peering

**Cause:** The `Network Contributor` role assignment for Confluent's service principal has not propagated in Azure AD.

**Fix:**

- Verify the role assignment exists: `az role assignment list --assignee <confluent-sp-object-id> --scope /subscriptions/<subscription-id>`
- If newly created, wait 15-30 minutes and retry.
- See `SETUP.md` section 4 for the exact commands.

---

## 6) Terraform destroy fails with timeout errors

**Cause:** Azure resource deletions (VMs, private endpoints, DNS links) can take 10-30 minutes and may exceed Terraform's default timeout.

**Fix:**

- Re-run `terraform -chdir=terraform destroy -auto-approve`.
- If the `for_each` error on private endpoints blocks planning, use targeted destroy:

```bash
terraform -chdir=terraform state list
# Then destroy remaining resources by target
terraform -chdir=terraform destroy -target=<resource.name> -auto-approve
```

---

## 7) WireGuard shows no handshake after VM recreate

**Cause:** The local `wireguard-client.conf` contains the old VM public IP as the endpoint.

**Fix:**

```bash
VM_IP=$(terraform -chdir=terraform output -raw vm_public_ip)
ssh -i demo_vm_key azureuser@$VM_IP "sudo cat /tmp/client.conf" > wireguard-client.conf
sudo wg-quick down ./wireguard-client.conf || true
sudo wg-quick up ./wireguard-client.conf
```

---

## 8) Consumer does not resume at correct offset on Cluster B

**Possible causes:**

- Offset sync interval has not elapsed (default 5 seconds). Wait at least 10 seconds after stopping the consumer on A before starting on B.
- Consumer group ID mismatch. Verify both `use-cluster-a.sh` and `use-cluster-b.sh` export the same `KAFKA_GROUP_ID`.
- `consumer.offset.sync.enable` is not set to `true` on the cluster link. Verify with:

```bash
confluent kafka link describe <link-name> --cluster <cluster-b-id> --environment <env-id>
```

---

## 9) Orphaned Confluent clusters block network deletion

**Symptom:** `terraform destroy` fails with HTTP 409 Conflict when deleting a Confluent network.

**Cause:** A cluster exists in Confluent Cloud but not in Terraform state (from a previous failed apply).

**Fix:** Delete the orphaned cluster via API:

```bash
curl -s -X DELETE \
  "https://api.confluent.cloud/cmk/v2/clusters/<cluster-id>?environment=<env-id>" \
  -u "<cloud-api-key>:<cloud-api-secret>"
```
