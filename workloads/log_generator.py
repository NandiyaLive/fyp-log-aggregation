#!/usr/bin/env python3
import json
import random
import os
from datetime import datetime, timezone
import argparse

random.seed(os.environ.get('LOG_SEED', '42'))

LOG_TEMPLATES = {
    'connection': [
        "Connection timeout to backend service {service} after {timeout}ms",
        "Failed to connect to database {db_host}:{port} - retrying...",
        "TCP connection established to {endpoint} in {latency}ms",
        "SSL handshake failed with {host}: {error_code}",
        "Connection pool exhausted for {service}, waiting {wait_time}ms",
    ],
    'error': [
        "ERROR: NullPointerException in {class_name} at line {line_num}",
        "CRITICAL: Disk usage exceeded {percent}% on volume {volume_id}",
        "ERROR: Request {request_id} failed with status {status_code}",
        "FATAL: OutOfMemoryError in pod {pod_name} container {container}",
        "ERROR: Failed to process message {message_id} from queue {queue}",
    ],
    'info': [
        "User {user_id} logged in from {ip_address}",
        "Order {order_id} processed successfully in {duration}s",
        "Cache hit ratio: {ratio}% for key pattern {pattern}",
        "Scheduled job {job_name} started at {timestamp}",
        "API request /{endpoint} completed in {latency}ms",
    ],
    'retry': [
        "Retry attempt {attempt} for operation {op_id} failed, backing off {backoff}ms",
        "Circuit breaker {cb_name} opened after {failure_count} failures",
        "Retrying request to {url} (attempt {attempt}/{max_attempts})",
        "Exponential backoff triggered for service {service}, next retry in {delay}s",
        "Bulk operation {batch_id} retrying {count} failed items",
    ],
    'kubernetes': [
        "Pod {pod_name} in namespace {namespace} status changed to {status}",
        "Container {container} restarted {restart_count} times in pod {pod_name}",
        "Node {node} taint {taint} applied at {timestamp}",
        "Deployment {deployment} scaled to {replicas} replicas",
        "Volume {pvc} bound to claim {claim} in namespace {namespace}",
    ]
}

def generate_variables():
    return {
        'service': random.choice(['user-service', 'payment-api', 'inventory-db', 'auth-service', 'notification-svc']),
        'timeout': random.randint(1000, 30000),
        'db_host': random.choice(['postgres-0', 'mysql-primary', 'mongo-rs-1']),
        'port': random.choice([5432, 3306, 27017, 6379, 9200]),
        'latency': random.randint(5, 500),
        'error_code': random.choice(['ECONNREFUSED', 'ETIMEDOUT', 'EHOSTUNREACH', 'SSLV3_ALERT']),
        'wait_time': random.randint(100, 5000),
        'class_name': random.choice(['UserController', 'PaymentGateway', 'AuthFilter', 'OrderProcessor']),
        'line_num': random.randint(1, 500),
        'percent': random.randint(85, 99),
        'volume_id': f"vol-{random.randint(1000, 9999)}",
        'request_id': f"req-{random.randint(100000, 999999)}",
        'status_code': random.choice([500, 502, 503, 504, 408]),
        'pod_name': f"app-{random.randint(1, 10)}-{random.randint(100, 999)}",
        'container': random.choice(['app', 'sidecar', 'init', 'nginx']),
        'message_id': f"msg-{random.randint(10000, 99999)}",
        'queue': random.choice(['orders', 'payments', 'notifications', 'events']),
        'user_id': f"user-{random.randint(1, 10000)}",
        'ip_address': f"10.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(1,254)}",
        'order_id': f"ORD-{random.randint(100000, 999999)}",
        'duration': round(random.uniform(0.1, 5.0), 2),
        'ratio': round(random.uniform(60, 95), 1),
        'pattern': random.choice(['user:*', 'session:*', 'product:*', 'cart:*']),
        'job_name': random.choice(['cleanup', 'backup', 'sync', 'report']),
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'attempt': random.randint(1, 5),
        'op_id': f"op-{random.randint(1000, 9999)}",
        'backoff': random.randint(100, 10000),
        'cb_name': random.choice(['db-cb', 'api-cb', 'external-cb']),
        'failure_count': random.randint(5, 20),
        'url': random.choice(['/api/v1/users', '/api/v2/payments', '/health', '/metrics']),
        'max_attempts': random.randint(3, 10),
        'delay': random.randint(1, 30),
        'batch_id': f"batch-{random.randint(100, 999)}",
        'count': random.randint(1, 100),
        'namespace': random.choice(['default', 'production', 'staging', 'logging']),
        'status': random.choice(['Running', 'Pending', 'Failed', 'Succeeded']),
        'restart_count': random.randint(1, 50),
        'node': f"node-{random.randint(1, 5)}",
        'taint': random.choice(['dedicated=gpu:NoSchedule', 'node.kubernetes.io/disk-pressure:NoSchedule']),
        'deployment': random.choice(['web-app', 'api-gateway', 'worker', 'scheduler']),
        'replicas': random.randint(1, 10),
        'pvc': f"pvc-{random.randint(100, 999)}",
        'claim': random.choice(['data', 'logs', 'config', 'cache']),
        'endpoint': random.choice(['users', 'orders', 'products', 'health']),
    }

def generate_unique_log():
    template_type = random.choice(list(LOG_TEMPLATES.keys()))
    template = random.choice(LOG_TEMPLATES[template_type])
    variables = generate_variables()
    try:
        message = template.format(**variables)
    except KeyError:
        message = template
    log_entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": random.choice(['INFO', 'WARN', 'ERROR', 'DEBUG']),
        "component": template_type,
        "message": message,
        "pod": variables.get('pod_name', f"workload-{random.randint(1,5)}"),
        "namespace": variables.get('namespace', 'default'),
        "trace_id": f"trace-{random.randint(100000, 999999)}",
        "duplication_group": hash(template) % 100000
    }
    return json.dumps(log_entry)

def generate_logs(total_logs=1_000_000, duplicate_ratio=0.5, output_file="/tmp/workload.log", seed="42"):
    random.seed(seed)
    unique_count = int(total_logs * (1 - duplicate_ratio))
    duplicate_count = total_logs - unique_count
    print(f"Generating {total_logs} logs: {unique_count} unique, {duplicate_count} duplicates")

    logs = []
    for i in range(unique_count):
        logs.append(generate_unique_log())
        if i % 100000 == 0:
            print(f"  {i} unique...")

    for i in range(duplicate_count):
        if unique_count > 0:
            source_log = json.loads(logs[random.randrange(unique_count)])
        else:
            source_log = json.loads(generate_unique_log())
        source_log['timestamp'] = datetime.now(timezone.utc).isoformat()
        logs.append(json.dumps(source_log))
        if i % 100000 == 0:
            print(f"  {i} duplicates...")

    random.shuffle(logs)

    # Write to a temp file first, then atomically rename. The emitter waits
    # for the final path, so it never reads a partially-written file.
    tmp_file = output_file + ".partial"
    with open(tmp_file, 'w') as f:
        for log in logs:
            f.write(log + '\n')
    os.rename(tmp_file, output_file)
    print(f"Done: {output_file} ({len(logs)} lines)")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--total', type=int, default=1_000_000)
    parser.add_argument('--dup-ratio', type=float, default=0.5)
    parser.add_argument('--output', default='/tmp/workload.log')
    parser.add_argument('--seed', default='42')
    args = parser.parse_args()
    generate_logs(args.total, args.dup_ratio, args.output, args.seed)
