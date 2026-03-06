#!/usr/bin/env python3
import json
import os
import signal
import sys
import time
from pathlib import Path

from confluent_kafka import Consumer, KafkaException, KafkaError
from dotenv import load_dotenv


def _parse_properties_file(path: str) -> dict:
    props = {}
    p = Path(path)
    if not p.exists():
        return props
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return props


def load_kafka_config() -> tuple[dict, str]:
    load_dotenv(override=False)

    config_file = os.getenv("CLIENT_PROPERTIES_PATH", "client.properties")
    file_props = _parse_properties_file(config_file)

    bootstrap = os.getenv("KAFKA_BOOTSTRAP_SERVERS") or file_props.get("bootstrap.servers")
    api_key = os.getenv("KAFKA_API_KEY") or file_props.get("sasl.username")
    api_secret = os.getenv("KAFKA_API_SECRET") or file_props.get("sasl.password")
    topic = os.getenv("KAFKA_TOPIC", "retail.orders.v1")
    group_id = os.getenv("KAFKA_GROUP_ID", "retail-orders-demo-consumer")

    if not bootstrap or not api_key or not api_secret:
        raise RuntimeError(
            "Missing Kafka credentials. Provide KAFKA_BOOTSTRAP_SERVERS/KAFKA_API_KEY/"
            "KAFKA_API_SECRET env vars or a client.properties file."
        )

    return (
        {
            "bootstrap.servers": bootstrap,
            "security.protocol": "SASL_SSL",
            "sasl.mechanism": "PLAIN",
            "sasl.username": api_key,
            "sasl.password": api_secret,
            "group.id": group_id,
            "client.id": os.getenv("KAFKA_CLIENT_ID", "retail-order-consumer"),
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "session.timeout.ms": int(os.getenv("KAFKA_SESSION_TIMEOUT_MS", "45000")),
            "max.poll.interval.ms": int(os.getenv("KAFKA_MAX_POLL_INTERVAL_MS", "300000")),
        },
        topic,
    )


def main() -> None:
    consumer_cfg, topic = load_kafka_config()
    commit_every = int(os.getenv("COMMIT_EVERY_MESSAGES", "10"))
    poll_timeout = float(os.getenv("CONSUMER_POLL_TIMEOUT_SECONDS", "1.0"))

    consumer = Consumer(consumer_cfg)
    consumer.subscribe([topic])

    should_run = True
    processed_since_commit = 0

    def _shutdown(*_args):
        nonlocal should_run
        should_run = False

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    print(f"[consumer] started topic={topic} group.id={consumer_cfg['group.id']}")
    try:
        while should_run:
            msg = consumer.poll(poll_timeout)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                raise KafkaException(msg.error())

            processed_since_commit += 1

            try:
                value = json.loads(msg.value().decode("utf-8"))
            except Exception:
                value = {"raw": msg.value().decode("utf-8", errors="replace")}

            print(
                f"[consumer] topic={msg.topic()} partition={msg.partition()} "
                f"offset={msg.offset()} key={msg.key().decode('utf-8', errors='replace') if msg.key() else None} "
                f"value={value}"
            )

            # Sync commit in small batches to preserve offsets for failover.
            if processed_since_commit >= commit_every:
                consumer.commit(asynchronous=False)
                processed_since_commit = 0
                print("[consumer] committed offsets")
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print(f"[consumer] fatal error: {exc}", file=sys.stderr)
        raise
    finally:
        try:
            if processed_since_commit > 0:
                consumer.commit(asynchronous=False)
                print("[consumer] committed final offsets")
        except Exception as commit_exc:
            print(f"[consumer] final commit failed: {commit_exc}", file=sys.stderr)

        # Give the coordinator a moment before closing to reduce rebalance churn.
        time.sleep(0.25)
        consumer.close()
        print("[consumer] stopped")


if __name__ == "__main__":
    main()
