#!/usr/bin/env python3
"""Synthetic log generator for the log-aggregation experiment.

Design contract (this is what makes the experiment valid):

    The pipelines deduplicate on a *normalized template signature*
    (level | component | message-with-numbers/IPs/strings blanked out).
    Therefore the only quantity that controls storage reduction is the
    number of DISTINCT signatures in the stream, NOT the number of
    byte-identical lines. This generator makes `dup_ratio` control exactly
    that quantity.

    Let N = total_logs and r = dup_ratio. We emit
        U = round(N * (1 - r))            distinct semantic events
        N - U                             repeats of those events
    Every distinct event is given a unique, normalization-surviving
    `entity` token (lowercase letters only, so it is not collapsed by the
    {NUM}/{IP}/{STR} rules). Each event therefore has its own signature,
    and repeats reuse an existing event's signature verbatim.

    Consequences the analysis relies on:
        deduped documents  M  == U            (one doc per distinct signature)
        theoretical SRR        == 1 - U/N == r
        compression efficiency == N / U   == 1 / (1 - r)

    Repeats are drawn with a Zipf-like bias (a few "hot" events dominate),
    which is realistic for production logs and does not change M.

Reproducibility: every byte of a given event is derived from
(seed, event_index) only; timestamps are the sole per-line wall-clock field
and are excluded from the signature, so a re-run with the same seed produces
the same distinct-event set and the same signatures.
"""
import argparse
import json
import os
import random
from datetime import datetime, timedelta, timezone

# Every template carries an {entity} token. The entity is the stable identity
# of the semantic event; the remaining {placeholders} are noise that the
# pipeline normalization is expected to blank out (numbers, IPs, ids).
LOG_TEMPLATES = {
    "connection": [
        "Connection timeout to backend service {entity} after {timeout}ms",
        "Failed to connect to database {entity} at {db_host}:{port} - retrying",
        "TCP connection established to {entity} in {latency}ms",
        "SSL handshake failed with {entity}: {error_code}",
        "Connection pool exhausted for {entity}, waiting {wait_time}ms",
    ],
    "error": [
        "NullPointerException in {entity} at line {line_num}",
        "Disk usage exceeded {percent}% on volume {entity}",
        "Request to {entity} failed with status {status_code} (req {request_id})",
        "OutOfMemoryError in pod {entity} container {container}",
        "Failed to process message {message_id} from queue {entity}",
    ],
    "info": [
        "User {entity} logged in from {ip_address}",
        "Order for {entity} processed successfully in {duration}s",
        "Cache hit ratio {ratio}% for key pattern {entity}",
        "Scheduled job {entity} started, run {request_id}",
        "Endpoint {entity} completed in {latency}ms",
    ],
    "retry": [
        "Retry attempt {attempt} for operation {entity} failed, backing off {backoff}ms",
        "Circuit breaker {entity} opened after {failure_count} failures",
        "Retrying request to {entity} (attempt {attempt}/{max_attempts})",
        "Exponential backoff triggered for service {entity}, next retry {delay}s",
        "Bulk operation {entity} retrying {count} failed items",
    ],
    "kubernetes": [
        "Pod {entity} in namespace {namespace} status changed to {status}",
        "Container {container} restarted {restart_count} times in pod {entity}",
        "Node {entity} taint {taint} applied",
        "Deployment {entity} scaled to {replicas} replicas",
        "Volume {entity} bound to claim {claim} in namespace {namespace}",
    ],
}

_TEMPLATE_TYPES = list(LOG_TEMPLATES.keys())
_LEVELS = ["INFO", "WARN", "ERROR", "DEBUG"]


def idx_to_token(i):
    """Bijective base-26 encoding of a non-negative int into lowercase letters.

    Letters only -> survives the {NUM}/{IP}/{STR} normalization, so it acts as
    a stable, unique signature component per distinct event.
    """
    s = []
    i += 1
    while i > 0:
        i, rem = divmod(i - 1, 26)
        s.append(chr(97 + rem))
    return "".join(reversed(s))


def render_noise(rng):
    """Per-event noise variables. All are numeric / id-like on purpose: the
    pipeline normalization is expected to collapse them to {NUM}/{IP}/{STR}."""
    return {
        "timeout": rng.randint(1000, 30000),
        "db_host": rng.choice(["postgres-0", "mysql-primary", "mongo-rs-1"]),
        "port": rng.choice([5432, 3306, 27017, 6379, 9200]),
        "latency": rng.randint(5, 500),
        "error_code": rng.choice(["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH"]),
        "wait_time": rng.randint(100, 5000),
        "line_num": rng.randint(1, 500),
        "percent": rng.randint(85, 99),
        "request_id": f"req-{rng.randint(100000, 999999)}",
        "status_code": rng.choice([500, 502, 503, 504, 408]),
        "container": rng.choice(["app", "sidecar", "init", "nginx"]),
        "message_id": f"msg-{rng.randint(10000, 99999)}",
        "ip_address": f"10.{rng.randint(0,255)}.{rng.randint(0,255)}.{rng.randint(1,254)}",
        "duration": round(rng.uniform(0.1, 5.0), 2),
        "ratio": round(rng.uniform(60, 95), 1),
        "attempt": rng.randint(1, 5),
        "backoff": rng.randint(100, 10000),
        "failure_count": rng.randint(5, 20),
        "max_attempts": rng.randint(3, 10),
        "delay": rng.randint(1, 30),
        "count": rng.randint(1, 100),
        "namespace": rng.choice(["default", "production", "staging", "logging"]),
        "status": rng.choice(["Running", "Pending", "Failed", "Succeeded"]),
        "restart_count": rng.randint(1, 50),
        "taint": rng.choice(["disk-pressure:NoSchedule", "gpu:NoSchedule"]),
        "replicas": rng.randint(1, 10),
        "claim": rng.choice(["data", "logs", "config", "cache"]),
    }


def render_event(idx, base_seed):
    """Deterministically render the *content* of distinct event `idx`.

    Returns a dict WITHOUT a timestamp (the timestamp is added per emitted
    line and is excluded from the dedup signature). Identical for every
    occurrence of the event, so repeats are true content duplicates.
    """
    rng = random.Random(base_seed * 1_000_003 + idx)
    ttype = _TEMPLATE_TYPES[idx % len(_TEMPLATE_TYPES)]
    template = rng.choice(LOG_TEMPLATES[ttype])
    level = _LEVELS[(idx // len(_TEMPLATE_TYPES)) % len(_LEVELS)]
    entity = idx_to_token(idx)
    variables = render_noise(rng)
    variables["entity"] = entity
    try:
        message = template.format(**variables)
    except KeyError:
        message = template
    return {
        "level": level,
        "component": ttype,
        "message": message,
        "entity": entity,
        "event_id": entity,
        "pod": f"workload-{(idx % 5) + 1}",
        "namespace": variables["namespace"],
    }


def zipf_index(rng, n, skew):
    """Pick an index in [0, n) biased toward small indices (hot events)."""
    return min(n - 1, int(n * (rng.random() ** skew)))


def generate_logs(total_logs, duplicate_ratio, output_file, seed, zipf_skew=2.0):
    base_seed = int(seed) if str(seed).lstrip("-").isdigit() else (hash(seed) & 0x7FFFFFFF)
    rng = random.Random(base_seed)

    unique_count = max(1, round(total_logs * (1 - duplicate_ratio)))
    unique_count = min(unique_count, total_logs)
    duplicate_count = total_logs - unique_count
    print(
        f"Generating {total_logs} logs: {unique_count} distinct events, "
        f"{duplicate_count} repeats (target SRR={duplicate_ratio:.4f})"
    )

    # Slot plan: each distinct event appears at least once, then repeats are
    # sampled (Zipf) from the distinct set. Holding N ints is cheap (~8 MB);
    # event content is rendered on the fly so we never buffer N strings.
    slots = list(range(unique_count))
    for _ in range(duplicate_count):
        slots.append(zipf_index(rng, unique_count, zipf_skew))
    rng.shuffle(slots)

    # Stable, monotonically increasing synthetic timestamps (deterministic).
    t0 = datetime(2025, 1, 1, tzinfo=timezone.utc)

    cache = {}
    tmp_file = output_file + ".partial"
    with open(tmp_file, "w") as f:
        for i, idx in enumerate(slots):
            event = cache.get(idx)
            if event is None:
                event = render_event(idx, base_seed)
                # Bound cache memory: only worth caching hot (reused) events,
                # which under Zipf are the low indices.
                if idx < 50000:
                    cache[idx] = event
            record = dict(event)
            record["timestamp"] = (t0 + timedelta(microseconds=i)).isoformat()
            record["trace_id"] = f"trace-{rng.randint(100000, 999999)}"
            f.write(json.dumps(record) + "\n")
            if i % 100000 == 0:
                print(f"  {i}/{total_logs}...")
    os.rename(tmp_file, output_file)
    print(f"Done: {output_file} ({len(slots)} lines, {unique_count} distinct)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--total", type=int, default=1_000_000)
    parser.add_argument("--dup-ratio", type=float, default=0.5)
    parser.add_argument("--output", default="/tmp/workload.log")
    parser.add_argument("--seed", default=os.environ.get("LOG_SEED", "42"))
    parser.add_argument("--zipf-skew", type=float, default=2.0)
    args = parser.parse_args()
    generate_logs(args.total, args.dup_ratio, args.output, args.seed, args.zipf_skew)
