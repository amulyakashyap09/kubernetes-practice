# Chapter 1 – Linux cgroups & Docker Resource Management

> Revision notes from hands-on labs.

## Key Concepts

### What are cgroups?
- Linux kernel feature to **limit, account and isolate** CPU, memory, I/O and processes.
- Docker, Kubernetes and systemd all rely on cgroups.

---

## cgroup v2 Important Files

| File | Purpose |
|------|---------|
| `cpu.max` | CPU quota (`quota period`) |
| `memory.max` | Hard memory limit |
| `memory.current` | Current memory usage |
| `memory.oom.group` | Kill entire cgroup on OOM (`1`) |
| `cgroup.procs` | Move processes into a cgroup |
| `cgroup.freeze` | Freeze (`1`) / thaw (`0`) processes |

---

## CPU Limits

Default period:

```text
100000 µs
```

Examples:

```bash
echo "10000 100000" > cpu.max   # 10%
echo "20000 100000" > cpu.max   # 20%
echo "50000 100000" > cpu.max   # 50%
```

Formula:

```
quota = percentage × 100000
```

---

## Memory Limits

```bash
echo 500M > memory.max
```

or

```bash
echo 524288000 > memory.max
```

---

## Running a Process in a cgroup

```bash
mkdir /sys/fs/cgroup/hog_pen

echo 500M > /sys/fs/cgroup/hog_pen/memory.max
echo "10000 100000" > /sys/fs/cgroup/hog_pen/cpu.max

sh -c 'echo $$ > /sys/fs/cgroup/hog_pen/cgroup.procs; exec /usr/local/bin/omnihog'
```

Why `exec`?
- Replaces the shell with the target process.
- Children automatically inherit the cgroup.

---

## Freeze / Thaw

Freeze:

```bash
echo 1 > cgroup.freeze
```

Resume:

```bash
echo 0 > cgroup.freeze
```

While frozen:
- CPU usage stops.
- Memory stays allocated.
- Process is paused, not terminated.

---

## OOM Group Killing

Default:

```text
memory.oom.group = 0
```

Kernel kills one process.

Recommended for master-worker apps:

```bash
echo 1 > memory.oom.group
```

Kernel kills the entire process group.

Useful for:
- Nginx
- PostgreSQL
- Multi-process applications
- Containers with worker processes

---

## Docker Resource Limits

```bash
docker run \
  --memory=500m \
  --cpus=1 \
  IMAGE
```

Maps internally to cgroups:
- `memory.max`
- `cpu.max`

Useful commands:

```bash
docker stats
docker inspect <container>
```

---

## Diagnosing systemd Services

```bash
systemctl status SERVICE
journalctl -u SERVICE
journalctl -k
systemctl cat SERVICE
```

Common issue:

```
Result: oom-kill
```

Fix:
- Increase `MemoryMax`
- Remove restrictive limits if appropriate

---

## Docker Compose

Per-container limits are **not** the same as limiting the whole application.

To limit an application:
- Create a common parent cgroup/systemd slice.
- Apply CPU and memory limits to the parent.
- Launch all containers under that parent.

---

## Debugging Commands

```bash
cat /proc/<pid>/cgroup
cat /sys/fs/cgroup/<group>/memory.current
cat /sys/fs/cgroup/<group>/cpu.stat
cat /sys/fs/cgroup/<group>/cpu.max
cat /sys/fs/cgroup/<group>/memory.max
```

Docker:

```bash
docker ps
docker stats
docker inspect
docker compose ps
```

Systemd:

```bash
systemctl status
systemctl show
systemctl cat
```

---

# Interview Nuggets

- Docker resource limits are implemented using Linux cgroups.
- `memory.oom.group=1` prevents partially alive multi-process applications.
- `cgroup.freeze` pauses execution without killing processes.
- `cgroup.procs` moves processes into a cgroup.
- Docker with the **systemd cgroup driver** places containers into `docker-*.scope`.

---

# Quick Revision Checklist

- ☐ Create a cgroup
- ☐ Set CPU limit (`cpu.max`)
- ☐ Set memory limit (`memory.max`)
- ☐ Move a process (`cgroup.procs`)
- ☐ Freeze and thaw (`cgroup.freeze`)
- ☐ Enable group OOM (`memory.oom.group`)
- ☐ Diagnose OOM using `systemctl` + `journalctl`
- ☐ Limit Docker containers
- ☐ Understand Docker Compose + common parent cgroups
- ☐ Inspect cgroup hierarchy via `/proc/<pid>/cgroup`
