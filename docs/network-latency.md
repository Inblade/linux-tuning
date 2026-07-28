# Network latency tuning

Techniques for shaving microseconds-to-milliseconds off the network path,
ordered roughly from "safe and general" to "specialized". Pair with
[`../sysctl/99-network-tuning.conf`](../sysctl/99-network-tuning.conf) and
verify each change with a load test that measures tail latency, not averages.

## Measure first

```bash
# Baseline RTT under load (TCP, from a client host):
# p99.9 is the number that pages you, not the mean.
wrk2 -t4 -c256 -R 20000 -d 60s --latency http://target:8080/

# Where drops happen on the host:
netstat -s | grep -iE 'drop|overflow|prune|collapse'
cat /proc/net/softnet_stat        # col 2 (hex) = dropped in backlog
ethtool -S eth0 | grep -iE 'drop|miss|err'
```

## Ring buffers

The NIC ring is the first queue a packet meets. Too small → drops during
bursts (`rx_missed`/`rx_no_buffer` in `ethtool -S`); too large → extra
latency and cache pressure, since a burst must drain through a longer queue.

```bash
ethtool -g eth0            # current vs hardware max
ethtool -G eth0 rx 1024 tx 1024
```

Guidance: increase only while `ethtool -S` shows ring-related drops under
representative load. Maxing it "just in case" is bufferbloat at layer 1.

## Interrupt coalescing

The NIC batches packets per interrupt. More coalescing = fewer interrupts =
better throughput and worse latency. For latency-sensitive boxes, reduce it:

```bash
ethtool -c eth0
# Fire quickly, adaptively off (adaptive tuning optimizes for throughput):
ethtool -C eth0 adaptive-rx off rx-usecs 8 rx-frames 16
```

`rx-usecs 0-16` is the latency-oriented range. Watch CPU: at very high packet
rates, low coalescing can saturate the IRQ-handling cores — that's the trade.

## RSS, RPS, XPS

**RSS (hardware)** — the NIC hashes flows across multiple RX queues, each
with its own IRQ. This is the primary scaling mechanism; set the queue count
to the number of cores you dedicated to network processing and pin one IRQ
per core (see [numa.md](numa.md)):

```bash
ethtool -l eth0                 # available/current queue counts
ethtool -L eth0 combined 8
```

**RPS (software)** — spreads packet processing to other CPUs when the NIC
has fewer queues than you need (common on VMs and cheap NICs). Costs an IPI
per batch; skip it if RSS already covers your cores:

```bash
echo ff > /sys/class/net/eth0/queues/rx-0/rps_cpus
```

**XPS** — the transmit-side analog; keeps TX completion on the sending core:

```bash
echo 01 > /sys/class/net/eth0/queues/tx-0/xps_cpus
```

Keep the hash consistent: a flow should be handled end-to-end (RX IRQ →
softirq → application thread) on the same core or at least the same NUMA
node. `perf top` showing heavy `__skb_flow_dissect` on the wrong node means
placement is off.

## Busy polling

Instead of sleeping until an interrupt arrives, the kernel can spin polling
the NIC queue — removing interrupt+wakeup latency (typically 10–30 µs off
RTT) at the price of burning a core:

```bash
# Global (µs to poll on blocking reads / on select-poll-epoll):
sysctl -w net.core.busy_read=50
sysctl -w net.core.busy_poll=50
```

Per-socket via `SO_BUSY_POLL` is preferable — only the sockets that need it
pay for it. Rules:

- Only worth it when you have CPU to burn and the target is sub-100 µs.
- Combine with pinned application threads; a busy-polling thread that
  migrates defeats the purpose.
- For the extreme end (kernel-bypass territory: AF_XDP, DPDK), busy polling
  is the last stop before leaving the kernel stack entirely.

## Offloads: know what you're running

```bash
ethtool -k eth0 | grep -vE 'fixed'
```

- **GRO/TSO/GSO on** for throughput; GRO adds small batching latency —
  measurably relevant only in the sub-100 µs regime.
- **LRO off** if the box routes/bridges (breaks forwarding correctness).
- In VMs, offload behavior belongs to the hypervisor vNIC — benchmark, don't
  assume.

## Checklist for a new latency-sensitive host

1. Baseline p99/p999 with a representative load test.
2. Apply sysctl set; re-test.
3. Size RSS queues = network cores; pin IRQs; re-test.
4. Reduce coalescing (`rx-usecs 8-16`); re-test.
5. Ring buffers up only if `ethtool -S` shows drops; re-test.
6. Busy polling only if still above target and CPU headroom exists.
7. Record every knob in config management — a hand-tuned host that reboots
   into defaults is an incident waiting for a quiet weekend.
