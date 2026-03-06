# Live Demo Script

Operator script for presenting the VNet Peering to Private Link migration.

Each step includes the exact commands to run and suggested talk track.

---

## Objective

Demonstrate that Kafka workloads can migrate from VNet Peering (Cluster A) to Private Link (Cluster B) with:

- no application code changes
- consumer offset continuity across clusters
- controlled, safe producer cutover via mirror topic promotion

---

## Pre-Demo Checklist

- [ ] Infrastructure fully deployed (`SETUP.md` complete)
- [ ] WireGuard VPN connected
- [ ] Cluster B bootstrap resolves to `10.0.2.x`
- [ ] VM reachable via SSH (two terminal sessions)
- [ ] Python venv and dependencies installed on VM
- [ ] Confluent Cloud UI open with both clusters visible

---

## Step 1 — Introduction (show UI)

**Show:** both clusters in the Confluent Cloud environment.

**Talk track:**

- "This demo shows a live migration from VNet Peering to Azure Private Link using Cluster Linking."
- "Cluster A is the current source cluster on VNet Peering."
- "Cluster B is the destination cluster on Private Link."
- "The cluster link continuously replicates data and consumer offsets from A to B."
- "The key proof point today is consumer offset continuity during the failover."

---

## Step 2 — Start producer on Cluster A

**Terminal 1 (SSH to VM):**

```bash
source .venv/bin/activate
source use-cluster-a.sh
python3 producer.py
```

**Talk track:**

- "The producer is now writing retail order events to Cluster A every half second."
- "This simulates continuous production traffic."

---

## Step 3 — Start consumer on Cluster A

**Terminal 2 (new SSH session to VM):**

```bash
source .venv/bin/activate
source use-cluster-a.sh
python3 consumer.py
```

**Talk track:**

- "The consumer reads from Cluster A and commits offsets in batches of 10."
- "Those committed offsets are continuously synced to Cluster B by the cluster link."

---

## Step 4 — Show replication status (UI)

**In Confluent Cloud UI:**

1. Navigate to Cluster B.
2. Open Cluster Linking.
3. Select mirror topic `retail.orders.v1`.
4. Confirm status is `ACTIVE` with low lag.

**Talk track:**

- "Cluster B is receiving mirrored data in near real time."
- "The mirror topic is read-only while mirroring is active — this prevents accidental dual writes."
- "We are ready for a live consumer failover."

---

## Step 5 — Consumer failover: A to B (proof moment)

**In Terminal 2:**

1. Stop consumer on Cluster A: `Ctrl+C`
2. Note the last `offset=` value printed.

```bash
echo "Waiting 10 seconds for final offset sync..."
sleep 10
source use-cluster-b.sh
python3 consumer.py
```

**Talk track:**

- "The producer is still running on Cluster A — it never stopped."
- "The consumer just restarted on Cluster B and resumed at the same offset."
- "That offset continuity is the proof of zero message loss during the cluster switch."
- "This is at-least-once delivery during migration: no data is lost. Brief replay of recent records can occur due to commit timing — that is expected, not data loss."

---

## Step 6 — Producer cutover to Cluster B

### 6a. Stop producer on A

**Terminal 1:** `Ctrl+C`

**Talk track:**

- "I am stopping the producer so the mirror can drain to zero lag before we promote."

### 6b. Pause consumer on B

**Terminal 2:** `Ctrl+C`

**Talk track:**

- "Pausing the consumer on B briefly — the promote step can stall if the destination consumer group is active."

### 6c. Promote mirror topic

**Terminal 2:**

```bash
~/promote-to-b.sh
```

Wait for `=== Done ===` message (typically 10-60 seconds).

**Talk track:**

- "The promote script verifies mirror lag is zero, checks that the consumer group is not active, then promotes the mirror topic."
- "Promotion converts the read-only mirror to a normal writable topic on Cluster B."
- "This is a one-way operation — the topic is now independent on Cluster B."

---

## Step 7 — Start both apps on Cluster B

**Terminal 1 (producer):**

```bash
source use-cluster-b.sh
python3 producer.py
```

**Terminal 2 (consumer):**

```bash
source use-cluster-b.sh
python3 consumer.py
```

**Talk track:**

- "Both producer and consumer are now running entirely on Cluster B over Private Link."
- "The application code is identical — only the connection configuration changed."
- "Migration is complete. Cluster A can be decommissioned at your convenience."

---

## Narration Guidance

| Do | Don't |
|---|---|
| Point to consumer `offset=` continuity as proof | Point to producer `sequence` as continuity proof (it resets on restart) |
| Describe brief replay as at-least-once behavior | Call replay "data loss" |
| Highlight that mirror was read-only until promoted | Imply dual writes were possible during migration |

---

## Common Q&A

**Q: What happens when Cluster B scales?**
A: Transparent to clients. Private DNS wildcard records handle all broker addressing automatically.

**Q: Can we use a custom domain like `kafka.example.com`?**
A: Not currently supported. TLS certificates are issued for the Confluent-provided domain.

**Q: How do we fail back to Cluster A?**
A: Create a reverse cluster link (B -> A), mirror the topic back, and promote on A. Best practice is to keep A running for a retention period before decommissioning.

**Q: What about Schema Registry?**
A: Schema Registry uses a public endpoint and continues to work unchanged with both clusters.
