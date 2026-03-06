# Security Notes

This repository is designed for **demonstration and enablement**. Several design choices prioritize ease of setup over production security posture.

---

## Demo-Oriented Choices

| Area | Demo behavior | Production recommendation |
|---|---|---|
| **Secrets in state** | Terraform state contains Confluent API keys and secrets | Use remote state with encryption (e.g., Azure Storage + customer-managed key) |
| **VM credential files** | Client properties with Kafka credentials are written to the VM filesystem | Use Azure Key Vault with VM managed identity for runtime secret retrieval |
| **SSH/WireGuard access** | Default source CIDR is `*` (open to all IPs) | Restrict `vm_source_address_prefix` to known operator CIDRs |
| **Service account scope** | Single service account with `CloudClusterAdmin` on both clusters | Separate service accounts per application with least-privilege roles |
| **cloud-init secrets** | Confluent Cloud API key/secret embedded in VM user-data | Inject secrets via managed identity or instance metadata at runtime |

---

## Before Sharing This Repository

Confirm none of the following are committed:

- [ ] `terraform.tfvars` (contains credentials)
- [ ] `terraform.tfstate` or `terraform.tfstate.backup` (contains credentials in state)
- [ ] SSH private keys (`*.pem`, `demo_vm_key`, etc.)
- [ ] `wireguard-client.conf` (contains VPN private key)
- [ ] Screenshots, logs, or notes with environment-specific IDs

The included `.gitignore` blocks all of these patterns by default.

---

## Production Hardening Checklist

- [ ] Store Terraform state in encrypted remote backend
- [ ] Use short-lived or rotatable API keys
- [ ] Restrict NSG rules to specific operator IP ranges
- [ ] Use separate Confluent service accounts with granular RBAC
- [ ] Enable audit logging on Confluent Cloud environment
- [ ] Apply organizational network governance policies
- [ ] Review and restrict Azure role assignments to minimum required scope
