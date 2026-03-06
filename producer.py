#!/usr/bin/env python3
import json
import os
import random
import signal
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from confluent_kafka import Producer
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
            "client.id": os.getenv("KAFKA_CLIENT_ID", "retail-order-producer"),
            "linger.ms": int(os.getenv("KAFKA_LINGER_MS", "50")),
            "acks": "all",
        },
        topic,
    )


_order_counter = 0


def make_mock_order() -> dict:
    global _order_counter
    _order_counter += 1
    sku = random.choice(
        [
            "SKU-TSHIRT-001",
            "SKU-JEANS-014",
            "SKU-SHOES-221",
            "SKU-MUG-330",
            "SKU-LAPTOP-505",
            "SKU-HEADSET-818",
        ]
    )
    return {
        "order_id": str(uuid.uuid4()),
        "sequence": _order_counter,
        "item_sku": sku,
        "price": round(random.uniform(5.99, 499.99), 2),
        "quantity": random.randint(1, 4),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def delivery_report(err, msg) -> None:
    if err is not None:
        print(f"[producer] delivery failed: {err}")
        return
    print(
        f"[producer] delivered topic={msg.topic()} partition={msg.partition()} "
        f"offset={msg.offset()}"
    )


def main() -> None:
    producer_cfg, topic = load_kafka_config()
    sleep_secs = float(os.getenv("PRODUCER_SLEEP_SECONDS", "0.5"))
    producer = Producer(producer_cfg)

    should_run = True

    def _shutdown(*_args):
        nonlocal should_run
        should_run = False

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    print(f"[producer] started topic={topic}")
    while should_run:
        order = make_mock_order()
        producer.produce(
            topic=topic,
            key=order["order_id"],
            value=json.dumps(order).encode("utf-8"),
            on_delivery=delivery_report,
        )
        producer.poll(0)
        time.sleep(sleep_secs)

    print("[producer] flushing in-flight messages...")
    producer.flush(15)
    print("[producer] stopped")


if __name__ == "__main__":
    main()
