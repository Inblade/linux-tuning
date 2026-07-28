# NUMA, IRQ affinity, and CPU isolation

Notes on placing latency-sensitive processes on multi-socket (and modern
chiplet) machines. Every technique here is a trade-off: you buy tail-latency
predictability by giving up scheduler flexibility and some aggregate
throughput. Measure before and after.

## Why NUMA matters

On a two-socket box, memory attached to the remote socket costs roughly
1.5–2x the latency of local memory, and cross-socket interconnect bandwidth
is finite. A process scheduled on node 0 with its memory on node 1 pays that
tax on every cache miss. Symptoms: inexplicably uneven p99 between identical
hosts, throughput that degrades as the machine "warms up".

Inspect the topology first:

```bash
numactl --hardware        # nodes, CPUs per node, per-node free memory
lscpu | grep -i numa
numastat -p <pid>         # where a process's memory actually lives
cat /sys/class/net/eth0/device/numa_node   # which node the NIC hangs off
```

## Pinning with numactl

Bind both CPU and memory — binding only CPUs still allows remote allocations:

```bash
# Run entirely on node 0 (CPUs + memory):
numactl --cpunodebind=0 --membind=0 ./server

# Interleave memory across nodes — for memory-bandwidth-bound processes
# larger than one node:
numactl --interleave=all ./big-cache
```

For systemd services:

```ini
[Service]
CPUAffinity=0-15
NUMAPolicy=bind
NUMAMask=0
```

Rules of thumb:

- Put the process on the **same node as the NIC** it serves (see
  `numa_node` above). RX packet processing touches memory the driver
  allocated on the NIC's node.
- If the working set fits in one node, **bind**; if it doesn't and access is
  uniform, **interleave**; a process silently overflowing its bound node will
  either OOM (strict membind) or quietly go remote (preferred policy).
- Disable `kernel.numa_balancing` for explicitly pinned workloads — automatic
  balancing adds page faults trying to "fix" placement you already fixed.

## IRQ affinity

By default `irqbalance` spreads NIC interrupts over all CPUs, including the
ones running your latency-critical threads. An IRQ landing on a busy core
preempts it and evicts cache.

```bash
# Which IRQs belong to the NIC:
grep eth0 /proc/interrupts

# Pin IRQ 63 to CPU 2 (bitmask):
echo 4 > /proc/irq/63/smp_affinity
# ...or by CPU list:
echo 2 > /proc/irq/63/smp_affinity_list
```

Practical pattern for a 32-core, single-NIC latency box:

1. Reserve a block of cores for the application (e.g. 8–31).
2. Steer NIC IRQs to the housekeeping cores (0–7) on the NIC's NUMA node,
   one queue per core (see RSS in
   [network-latency.md](network-latency.md)).
3. Either stop `irqbalance` or set `IRQBALANCE_BANNED_CPULIST` so it does not
   undo your pinning on the reserved cores.

## isolcpus and its trade-offs

Kernel cmdline isolation removes cores from the general scheduler entirely:

```
isolcpus=8-31 nohz_full=8-31 rcu_nocbs=8-31
```

- `isolcpus` — the scheduler will not place anything there; only explicit
  affinity (taskset/cpuset) gets a thread onto those cores.
- `nohz_full` — stop the periodic scheduler tick on those cores while they
  run a single thread (removes a ~1 kHz interruption source).
- `rcu_nocbs` — move RCU callback processing off those cores.

Trade-offs to accept before using it:

- **No load balancing.** If you pin two busy threads to one isolated core,
  the kernel will not rescue you — one starves. All placement becomes your
  responsibility.
- **Wasted capacity.** Isolated cores idle when the pinned workload is quiet;
  batch jobs can't soak them.
- **Operational surprise.** Cron jobs, kernel threads and monitoring agents
  crowd onto the shrunken housekeeping set; size it honestly (leave at least
  2–4 cores plus one per ~10 Gbit/s of NIC traffic).
- A softer alternative is **cpusets via systemd** (`AllowedCPUs=` /
  a partition of slices), which achieves most of the separation and stays
  adjustable at runtime — start there, reach for `isolcpus` only when the
  remaining tick/IRQ noise is provably your bottleneck.

## Verifying the result

```bash
# Per-node hit/miss counters (numa_miss growing = remote allocations):
numastat

# Where threads actually run over time:
pidstat -t -p <pid> 1     # last column: CPU

# Involuntary context switches on the pinned cores should approach zero:
perf stat -C 8-31 -e context-switches,cpu-migrations sleep 10
```

The end state worth aiming for: application threads never migrate, NIC IRQs
never land on application cores, and `numastat` shows local allocations
only. Then re-run your load test and compare p99/p999 — if they didn't move,
undo the complexity.
