# Setup Runbook

Complete deployment guide for the VNet Peering to Private Link migration demo.

---

## 1) Prerequisites

| Requirement | Details |
|---|---|
| Terraform | `>= 1.5` |
| Azure CLI | Logged in (`az login`) to the target subscription |
| Confluent Cloud | Org access to create environments, networks, Dedicated clusters, API keys, cluster links |
| SSH keypair | For VM access; generate with `ssh-keygen -t rsa -b 4096 -f demo_vm_key` |
| WireGuard client | Installed on operator laptop ([download](https://www.wireguard.com/install/)) |
| Python 3.10+ | For running producer/consumer apps |
| Confluent CLI | Optional but recommended for mirror status checks |

---

## 2) Generate SSH Key (if needed)

```bash
ssh-keygen -t rsa -b 4096 -f demo_vm_key -N ""
```

This creates `demo_vm_key` (private) and `demo_vm_key.pub` (public) in the repo root.

---

## 3) Prepare Terraform Inputs

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and fill in:

| Variable | Where to get it |
|---|---|
| `confluent_cloud_api_key` | Confluent Cloud > Settings > API keys > Cloud API keys |
| `confluent_cloud_api_secret` | Same as above |
| `vm_admin_public_key` | Contents of `demo_vm_key.pub` |
| `vm_admin_private_key_path` | Default `../demo_vm_key` works if key is in repo root |

Optionally override region, CIDRs, VM size, and tags.

---

## 4) Azure Role Prerequisite (Required for VNet Peering)

Confluent's service principal must have `Network Contributor` on your subscription before peering can be established.

```bash
CONFLUENT_APP_ID="f0955e3a-9013-4cf4-a1ea-21587621c9cc"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create the service principal in your tenant (idempotent — safe to re-run)
az ad sp show --id "$CONFLUENT_APP_ID" >/dev/null 2>&1 \
  || az ad sp create --id "$CONFLUENT_APP_ID"

CONFLUENT_SP_OBJECT_ID=$(az ad sp show --id "$CONFLUENT_APP_ID" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$CONFLUENT_SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

**Wait 15-30 minutes** after creating a new assignment for Azure AD propagation before running Phase 3.

---

## 5) Initialize Terraform

```bash
terraform -chdir=terraform init
```

---

## 6) Deploy in Phases

Phased deployment is required because Private Link service aliases (used as `for_each` keys for private endpoints) are only known after the Confluent network is created.

### Phase 1 — Private Link network

```bash
terraform -chdir=terraform apply \
  -target=confluent_network.cluster_b_private_link \
  -target=confluent_private_link_access.cluster_b \
  -auto-approve
```

### Phase 2 — Azure VNet + VM

```bash
terraform -chdir=terraform apply \
  -target=azurerm_resource_group.demo \
  -target=azurerm_virtual_network.demo \
  -target=azurerm_subnet.apps \
  -target=azurerm_subnet.private_endpoint \
  -target=azurerm_network_security_group.apps \
  -target=azurerm_subnet_network_security_group_association.apps \
  -target=azurerm_public_ip.vm \
  -target=azurerm_network_interface.vm \
  -target=azurerm_linux_virtual_machine.client_vm \
  -auto-approve
```

### Phase 2.5 — Connect WireGuard VPN

Wait ~3 minutes for cloud-init to complete on the VM, then:

```bash
VM_IP=$(terraform -chdir=terraform output -raw vm_public_ip)
ssh -i demo_vm_key azureuser@$VM_IP "sudo cat /tmp/client.conf" > wireguard-client.conf
sudo wg-quick up ./wireguard-client.conf
```

### Phase 2.6 — Verify DNS resolution

Use Python `socket.getaddrinfo` (not `dig`, which can bypass the VPN resolver):

```bash
CLUSTER_B_HOST=$(terraform -chdir=terraform output -raw cluster_b_bootstrap_server | cut -d: -f1)
python3 -c "import socket; print(socket.getaddrinfo('$CLUSTER_B_HOST', 443))"
```

**Expected:** addresses in `10.0.2.x` (private endpoint subnet). If you see `10.1.x.x`, the VPN DNS is not working correctly — see `TROUBLESHOOTING.md`.

### Phase 3 — Everything else (clusters, link, topic, VM config)

```bash
terraform -chdir=terraform apply -auto-approve
```

This phase takes ~50-60 minutes (Dedicated cluster provisioning).

---

## 7) Validate Deployment

```bash
terraform -chdir=terraform output
```

Key outputs to note:
- `ssh_command` — ready-to-use SSH command
- `cluster_a_bootstrap_server` / `cluster_b_bootstrap_server`
- `cluster_link_name`

---

## 8) VM Readiness Check

```bash
ssh -i demo_vm_key azureuser@$(terraform -chdir=terraform output -raw vm_public_ip)

# Verify scripts exist
ls ~/use-cluster-a.sh ~/use-cluster-b.sh ~/promote-to-b.sh

# Install Python dependencies
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

# Verify Confluent CLI (optional)
confluent version
```

---

## 9) Teardown

```bash
terraform -chdir=terraform destroy -auto-approve
sudo wg-quick down ./wireguard-client.conf
```

If destroy times out on long-running Azure deletions, re-run the command. See `TROUBLESHOOTING.md` for partial-destroy recovery.

---

## Next Step

Proceed to [`DEMOSCRIPT.md`](DEMOSCRIPT.md) for the live demo walkthrough.
