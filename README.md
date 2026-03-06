# Confluent Cloud Network Migration Demo (Azure)

Demonstrates a **zero-downtime Kafka migration** from **VNet Peering** to **Azure Private Link** using Confluent Cloud Cluster Linking.

---

## What This Demo Proves

1. **Continuous replication** — Cluster Linking mirrors topic data from a source cluster (VNet Peering) to a destination cluster (Private Link) in near real time.
2. **Consumer offset sync** — Consumer group offsets are synchronized across clusters so consumers can switch mid-stream without losing position.
3. **Controlled cutover** — The destination mirror topic is read-only until explicitly promoted, preventing accidental dual writes during migration.
4. **No application code changes** — Producer and consumer use identical logic on both clusters; only connection configuration changes.

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│  Azure VNet (10.0.0.0/16)                                           │
│                                                                     │
│  ┌──────────────┐     ┌──────────────────────────────────────────┐  │
│  │  VM subnet   │     │  Private Endpoint subnet                 │  │
│  │  10.0.1.0/26 │     │  10.0.2.0/27                             │  │
│  │              │     │                                          │  │
│  │  Ubuntu VM   │     │  PE-1 ──┐                                │  │
│  │  WireGuard   │     │  PE-2 ──┼── Private Link ── Cluster B    │  │
│  │  dnsmasq     │     │  PE-3 ──┘   (destination)                │  │
│  └──────────────┘     └──────────────────────────────────────────┘  │
│         │                                                           │
│         │  VNet Peering (10.50.0.0/16)                              │
│         └──────────────────────────── Cluster A (source)            │
└─────────────────────────────────────────────────────────────────────┘

  Laptop ── WireGuard tunnel ── VM ── reaches both clusters
```

- **Cluster A (source):** Confluent Cloud Dedicated, VNet Peering
- **Cluster B (destination):** Confluent Cloud Dedicated, Private Link
- **Cluster Link (A -> B):** mirrors topic data + consumer offsets
- **Azure VM:** WireGuard VPN + dnsmasq DNS forwarder, enabling operator access to private endpoints

---

## Repository Contents

| File / Directory | Purpose |
|---|---|
| `terraform/` | All infrastructure: Azure networking, VM, Confluent clusters, link, DNS |
| `producer.py` | Demo Kafka producer (writes mock retail orders) |
| `consumer.py` | Demo Kafka consumer (manual offset commits for clean failover) |
| `requirements.txt` | Python dependencies |
| `SETUP.md` | Full deployment runbook (phased Terraform apply) |
| `DEMOSCRIPT.md` | Step-by-step live demo flow with talk track |
| `RESET.md` | Reset topic/link between demo runs without rebuilding clusters |
| `TROUBLESHOOTING.md` | Common failure modes and fixes |
| `SECURITY.md` | Demo shortcuts and production hardening guidance |

---

## Quick Start

1. Review prerequisites and deploy infrastructure per [`SETUP.md`](SETUP.md).
2. Run the live migration walkthrough per [`DEMOSCRIPT.md`](DEMOSCRIPT.md).
3. Between repeated runs, use [`RESET.md`](RESET.md).
4. Tear down with `terraform -chdir=terraform destroy -auto-approve`.

---

## Estimated Deployment Time

| Phase | Duration |
|---|---|
| Phase 1 (Private Link network) | ~5 min |
| Phase 2 (VM + VNet) | ~2 min |
| Phase 2.5 (VPN connect + DNS verify) | ~3 min |
| Phase 3 (clusters + link + topic) | ~50-60 min |
| **Total** | **~60-70 min** |

---

## Important Notes

- No credentials are stored in this repository. All secrets are provided at apply time via `terraform.tfvars` (gitignored).
- Terraform state contains sensitive values; treat it accordingly (see [`SECURITY.md`](SECURITY.md)).
- Dedicated clusters incur hourly charges; destroy the environment promptly when not in use.
