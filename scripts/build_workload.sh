#!/bin/bash
# Build workload image and import to k3s
# Run once as neranjana

cd workloads
docker build -t workload-generator:latest .
docker save workload-generator:latest | sudo k3s ctr images import -
echo "Workload image imported"
