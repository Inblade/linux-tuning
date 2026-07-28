# linux-tuning

Linux performance tuning reference for latency-sensitive workloads — sysctl
sets, NUMA/IRQ placement notes, and a read-only audit script. Collected from
tuning production hosts (game servers, real-time APIs, proxies), generalized
here with the reasoning for every value.

> **Warning: there are no universally correct values.**
> Every knob in this repository changes a trade-off (latency vs throughput,
> memory vs stalls, CPU vs interrupts). A setting that fixed p99 on one
> workload has degraded it on another. **Load-test every change against your
> own traffic, one change at a time, watching tail latency (p99/p999) — never
> apply this wholesale to a fleet.**

## Structure

```
.
├── sysctl/
│   ├── 99-network-tuning.conf     # buffers, backlogs, TCP behavior, BBR/fq — each value commented
│   └── 99-vm-tuning.conf          # swappiness, dirty writeback, reclaim, THP, NUMA balancing
├── docs/
│   ├── numa.md                    # numactl, IRQ affinity, isolcpus and its trade-offs
│   └── network-latency.md         # ring buffers, coalescing, RSS/RPS/XPS, busy polling
├── scripts/
│   └── tune-check.sh              # current vs recommended values — read-only
├── LICENSE
└── README.md
```

## Usage

Audit a host first (changes nothing):

```bash
./scripts/tune-check.sh
```

Apply selectively, after reading the comments and testing:

```bash
sudo cp sysctl/99-network-tuning.conf /etc/sysctl.d/
sudo cp sysctl/99-vm-tuning.conf /etc/sysctl.d/
sudo sysctl --system
```

Then re-run `tune-check.sh` and — more importantly — your load test.

## Method

1. **Baseline** — measure p99/p999 under representative load before touching
   anything (`wrk2`, `tcpdump`, `netstat -s`, `ethtool -S`).
2. **One change at a time** — apply a single knob or a small coherent group,
   re-test, keep or revert. Batched changes make regressions unattributable.
3. **Persist in config management** — anything set by hand evaporates on
   reboot; encode the final set in Ansible/cloud-init/image builds.
4. **Re-validate on kernel upgrades** — defaults and behaviors move between
   kernel versions (e.g. `tcp_tw_reuse` semantics, BBR revisions).

The docs cover the parts that are not sysctls: NUMA-aware process placement
and IRQ steering ([docs/numa.md](docs/numa.md)), and NIC-level latency work —
ring buffers, interrupt coalescing, RSS/RPS, busy polling
([docs/network-latency.md](docs/network-latency.md)).

## Scope

Targets modern x86_64/arm64 servers on kernel 5.15+. Values assume a
dedicated host with 10G+ networking and NVMe storage; VMs and containers
inherit some of these from the hypervisor/host and cannot set others —
`tune-check.sh` marks knobs missing in the current environment.

## License

MIT — see [LICENSE](LICENSE).
