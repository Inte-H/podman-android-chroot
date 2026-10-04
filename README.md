# podman-android-chroot

한국어: [README.ko.md](README.ko.md)

Run podman containers inside a Linux chroot on a rooted Android phone that still has its
**stock kernel**. No custom kernel, no firewall rules, no routes and no network devices are
added to the phone. A plain `podman run` starts the container jailed.

**Status: draft.** Everything below was measured on one phone:

| | |
|---|---|
| Phone | Samsung Galaxy S26 Ultra, stock firmware, rooted with KernelSU |
| Kernel | 6.12.30 (android16 GKI, Samsung build), arm64, 4 KiB pages |
| Chroot | Ubuntu 26.04 under Termux (chroot-distro), `/data` on f2fs |
| Software | podman 5.7.0, crun, slirp4netns, podman-compose 1.5.0 |

Other phones, other root solutions and other distributions are untested.

## What a stock Android kernel lacks

| Missing in the kernel | Consequence | What this setup does |
|---|---|---|
| PID namespaces | a container shares the phone's process table | `/proc` in the container hides other users' processes; jailed containers each get their own uid |
| User namespaces | a uid in the container is that uid on the phone; no rootless mode | jail mode picks an unused uid per container |
| IPC namespaces, SysV IPC | no isolated IPC; software that needs SysV shared memory does not start | `ipcns = host`; nothing replaces SysV IPC |
| POSIX message queues | podman's default `/dev/mqueue` mount fails | a tmpfs is mounted there |
| pids cgroup controller | no cgroup process limit | a per-uid `nproc` ulimit in jail mode |
| device cgroup controller | no device filtering by cgroup | jailed containers hold no capabilities |
| nftables | podman's bridge network fails | slirp4netns: a private network namespace without touching the phone's firewall |
| overlay on f2fs | the overlay storage driver fails | the vfs driver (see [Storage](#storage)) |

Network and UTS namespaces, cgroup v2 with the memory controller, seccomp and TUN are present
and used. `tools/check-kernel.sh` checks your kernel for the same list.

## Two commands

| Command | Container runs as | Use it for |
|---|---|---|
| `podman`, `docker` | **jailed**: an unused uid of its own, no capabilities, read-only root filesystem, memory limit (half of the phone's RAM), process limit | everything by default |
| `podman-trusted` | whatever the image asks for, usually root | images you trust that only start as root, such as the official `nginx` |

Both give the container its own network namespace, forbid privilege escalation
(`no-new-privileges`), and install "unreachable" routes inside the container for private
networks, the phone's own addresses and the networks the phone is attached to, so a container
reaches the internet but not the phone or the devices next to it. A bridge or named network
is refused before podman creates a bridge device on the phone.

Jail options sit in front of your own, so each can be overridden for one container, for
example `podman run --read-only=false ...` or `--memory 2g`.

**How strong is it.** A jailed container was confined in every attempt we made against it. A
container that runs as root through `podman-trusted` is only weakly confined: treat it as
running the image as root on your phone, and use it for images you trust. This README
deliberately gives the conclusion only.

## Install

Inside the chroot, as root:

```sh
apt install podman crun slirp4netns iproute2 procps    # plus podman-compose if wanted
sh tools/check-kernel.sh        # reads /proc/config.gz
bash install.sh
bash tools/verify.sh
```

`install.sh` puts `podman`, `docker` and `podman-trusted` into `/usr/local/bin`, the scripts
into `/usr/local/lib/podman-android`, and `containers.conf`, `storage.conf` and one OCI hook
into `/etc/containers`. Existing files in `/etc/containers` are kept; compare them with
`etc/` yourself. `PREFIX` and `ETCDIR` change the locations. To uninstall, delete those files.

Settings live in `/usr/local/lib/podman-android/config`:

| Variable | Meaning | Default |
|---|---|---|
| `ROOTFS` | the chroot's path as Android sees it | detected by `install.sh` |
| `SU` | how a non-root user becomes root (`su` binary or `sudo`) | `/system/bin/su` |
| `JAIL_UID_MIN`, `JAIL_UID_MAX` | uid range for jailed containers | 4100-4999 |
| `JAIL_MEMORY` | memory limit of a jailed container | half of the RAM |
| `JAIL_NPROC` | process and thread limit of a jailed container | 4096 |
| `NETGUARD_BLOCK4`, `NETGUARD_BLOCK6` | destinations containers must not reach | private, link-local and carrier-internal ranges |

The uid range must be one Android neither uses nor blocks: on the test phone a uid of 10000 or
above without an app behind it could not open sockets, and the 4000s were unused.

## What was tested

`tools/verify.sh` on the test phone:

```
podman run (jail):
  PASS  runs at all
  PASS  uid 4923 is inside 4100-4999
  PASS  no capabilities
  PASS  privilege escalation is off
  PASS  root filesystem is read-only
  PASS  own network namespace
  PASS  sees only its own processes (4 of 1133)
  PASS  memory limit is set (5831487488)
  PASS  private networks and the phone are unreachable
  PASS  internet works
podman-trusted run:
  PASS  runs as the image's user (uid 0)
  PASS  privilege escalation is off
  PASS  own network namespace
  PASS  private networks and the phone are unreachable
  PASS  internet works
bridge networks are refused before a device is created:
  PASS  refused with status 125
```

| Feature | Result |
|---|---|
| `podman run`, published ports (`-p`) | works; a non-root nginx answered HTTP 200 from the phone and from another machine on the same network |
| `podman run -it` | works in both modes (terminal allocated, input and output pass through) |
| `podman exec`, `stop`, `start` | work |
| `podman build` | works. The wrapper adds `--network=slirp4netns` and covers `/dev/mqueue`; without them the build fails |
| `podman-compose` | works in both modes when services avoid the bridge network: give the first service `network_mode: slirp4netns` and let the others join it with `network_mode: "service:NAME"` (see `examples/compose.yaml`). A compose file that uses the default network is refused |
| Pods | `podman pod create` works, but starting a container in a pod with an infra container fails (`"/dev/mqueue": duplicate mount destination`). The pod podman-compose creates has no infra container and works |
| Official `postgres` image | does not start: `shmget: Function not implemented` (no SysV IPC in the kernel) |

## Storage

The vfs driver needs no mounts, which is why it works here, but it stores a full copy of the
filesystem for every layer and every container. Two nginx images (64 MB and 56 MB) take
315 MB on disk; an image with many layers takes far more.

fuse-overlayfs was tested as the alternative. The same two images take 111 MB, and pulling,
running, building, `stop` and `start` work. It is **not** enabled, because with this setup's
design (every podman call gets a private mount namespace that disappears with its last
process) three things break:

- `podman exec` from a later call is killed by Samsung's DEFEX kernel protection;
- `podman restart` fails because the container's filesystem is mounted only in the namespace
  of the call that started it;
- `--read-only`, which jail mode uses, fails with `set xattr ... Permission denied` unless the
  read-only tmpfs mounts are turned off.

`exec` and `restart` do work when the later call joins the mount namespace of the running
container, so fuse-overlayfs is possible with a shared namespace. That is a redesign and is
not part of this draft.

## Limits

- **Jail mode needs images that run as a non-root user with a read-only root.** Images that
  insist on root (official `nginx`, most distribution images running services) need
  `podman-trusted` or an unprivileged variant such as `nginxinc/nginx-unprivileged`.
- **Build steps are not jailed.** `RUN` steps execute as root, see the phone's whole process
  table, and may escalate privileges. Build only Containerfiles you trust.
- **Published ports listen on all of the phone's addresses** unless you name one
  (`-p 127.0.0.1:8080:8080`).
- **Do not give containers `NET_ADMIN`.** With it the blocking routes can be removed from
  inside.
- **A long-running container does not learn new addresses.** The blocking routes are computed
  when the container starts; an address the phone receives later is not added.
- **Becoming root from a non-root user is unconfirmed.** On the test phone the wrapper was
  used from a root shell. From an ordinary user inside the chroot, Android's `su` could not
  start (Android's loader under `/apex` was not visible there) and `sudo` was killed by
  Samsung's DEFEX.
- **Two containers started at the same instant can draw the same uid** (the pick is random
  within the range and not reserved). They would then see each other's processes and share
  one process limit.
- **Every podman command prints** `Failed to read current user namespace mappings`. It is
  harmless: the kernel has no user namespaces.
- Only arm64 images were run. Images for other architectures are untested.

## How it works

```
podman (wrapper, in the chroot)
  -> nsenter into its own mount namespace, which leaves the chroot
  -> lib/enter.sh (Android's shell, root): new private mount namespace, the chroot becomes
     the root of it, cgroup2 and a process-hiding /proc are mounted
  -> lib/dispatch (root, inside that namespace): adds the jail options, the build options
     and the network checks
  -> the real /usr/bin/podman
```

Everything is mounted in a private mount namespace and disappears when the last process in
it exits. Nothing has to be unmounted by hand, and nothing on the Android side is changed.
`lib/netguard` is an OCI hook that adds the blocking routes inside each container's network
namespace.
