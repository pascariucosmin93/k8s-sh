# k8s-sh

Shell-based platform automation for building and maintaining a small bare-metal Kubernetes cluster.

This repository contains a practical set of scripts for:

- bootstrapping a kubeadm-based cluster
- installing Cilium as the primary CNI
- enabling Cilium BGP Control Plane
- adding worker nodes
- removing worker nodes cleanly
- managing FRR BGP neighbors on upstream routers

The scripts are inspired by a real homelab environment, but the public version is sanitized and parameterized for portfolio use.

## Scope

This project is intentionally opinionated. It targets:

- Ubuntu-based nodes
- kubeadm clusters
- containerd runtime
- Cilium with kube-proxy replacement
- bare-metal or homelab environments
- optional FRR-based upstream routing

It is not meant to be a universal cluster installer. It is a reusable example of how I automate the setup and lifecycle of an on-prem Kubernetes environment.

## Repository Layout

- `scripts/bootstrap-cluster.sh`: bootstrap a new control plane and initial workers
- `scripts/add-node.sh`: prepare and join a new worker
- `scripts/remove-node.sh`: drain, delete and reset a worker
- `scripts/router/add-bgp-neighbor.sh`: add a BGP neighbor to FRR
- `scripts/router/remove-bgp-neighbor.sh`: remove a BGP neighbor from FRR
- `manifests/cilium/`: sample manifests for Cilium BGP and LB IPAM

## Features

- disables swap and prepares Linux kernel settings
- installs and configures containerd
- installs Kubernetes packages via the official repository
- initializes a control plane with `kubeadm`
- installs Cilium with BGP control plane enabled
- creates sample `CiliumLoadBalancerIPPool` resources
- automates worker node joins
- optionally adds or removes FRR BGP neighbors
- supports topology labels for storage-aware environments

## Typical Workflow

### Bootstrap a new cluster

```bash
./scripts/bootstrap-cluster.sh \
  --control-plane x.x.x.x \
  --workers x.x.x.x,x.x.x.x,x.x.x.x \
  --ssh-user root \
  --router-peer x.x.x.x \
  --router-asn xxxx \
  --cluster-asn xxxx \
  --lb-pool-public x.x.x.0/24 \
  --lb-pool-private x.x.x.0/24
```

### Add a worker

```bash
./scripts/add-node.sh \
  --master x.x.x.x \
  --node x.x.x.x \
  --ssh-user root \
  --node-name worker-4 \
  --router1 x.x.x.x \
  --router2 x.x.x.x
```

### Remove a worker

```bash
./scripts/remove-node.sh \
  --master x.x.x.x \
  --node-name worker-4 \
  --node-host x.x.x.x \
  --ssh-user root \
  --router1 x.x.x.x \
  --router2 x.x.x.x
```

## Notes

- Replace all placeholder IPs and ASNs with values from your environment.
- Review every script before running it in a real cluster.
- The scripts assume passwordless SSH or an already-configured SSH workflow.
- FRR integration is optional but useful for bare-metal BGP-based service exposure.

## Why This Repo Matters

This repository demonstrates practical platform automation, not just application deployment.

It shows how I approach:

- cluster bootstrap
- repeatable node lifecycle management
- Cilium-first networking
- bare-metal routing with BGP
- router integration for on-prem service exposure
