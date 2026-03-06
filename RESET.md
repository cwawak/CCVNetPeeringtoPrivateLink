# Reset Between Demo Runs

Use this procedure to get a clean topic, cluster link, and mirror topic without tearing down and rebuilding the full infrastructure (clusters, VM, networking).

---

## 1) Destroy topic + link + mirror

```bash
terraform -chdir=terraform destroy \
  -target=confluent_kafka_mirror_topic.orders_on_cluster_b \
  -target=confluent_cluster_link.a_to_b \
  -target=confluent_kafka_topic.orders_cluster_a \
  -auto-approve
```

## 2) Recreate topic + link + mirror + VM scripts

```bash
terraform -chdir=terraform apply \
  -target=confluent_kafka_topic.orders_cluster_a \
  -target=confluent_cluster_link.a_to_b \
  -target=confluent_kafka_mirror_topic.orders_on_cluster_b \
  -target=null_resource.configure_vm_confluent \
  -auto-approve
```

> The `null_resource.configure_vm_confluent` target may show a warning if the VM already has the correct scripts. This is harmless.

## 3) Verify mirror is active

```bash
confluent kafka mirror describe retail.orders.v1 \
  --link cluster-a-to-cluster-b \
  --cluster <cluster-b-id> \
  --environment <environment-id>
```

Expected output:
- Mirror status: `ACTIVE`
- Partition mirror lag: `0`
- Last source fetch offset: `0`

## 4) Resume demo

Return to [`DEMOSCRIPT.md`](DEMOSCRIPT.md) Step 2.
