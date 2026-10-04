# podman-android-chroot

한국어: [README.ko.md](README.ko.md)

Run podman containers in a Linux chroot on a rooted Android phone with the stock kernel.

## Test environment

| | |
|---|---|
| Phone | Samsung Galaxy S26 Ultra, stock firmware, rooted with KernelSU |
| Kernel | 6.12.30 (android16 GKI, Samsung build), arm64, 4 KiB pages |
| Chroot | Ubuntu 26.04 under Termux (chroot-distro), `/data` on f2fs |
| Software | podman 5.7.0, crun, slirp4netns, podman-compose 1.5.0 |

## Install

Run every step below, and `podman` itself, as root inside the chroot.

1. Install the packages (add `podman-compose` if you want compose)

   ```sh
   apt install podman crun slirp4netns iproute2 procps
   ```

2. Check that your kernel is supported

   ```sh
   sh tools/check-kernel.sh
   ```

3. Run the installer

   ```sh
   bash install.sh
   ```

4. Verify the isolation (each check prints PASS or FAIL)

   ```sh
   bash tools/verify.sh
   ```

`install.sh` installs `podman`, `docker` and `podman-trusted` into `/usr/local/bin`, the scripts
into `/usr/local/lib/podman-android`, and `containers.conf`, `storage.conf` and one OCI hook
into `/etc/containers`. Existing `containers.conf`, `storage.conf` and `config` are not overwritten; merge changes from `etc/` and `lib/config` yourself.
`PREFIX` changes the install location. To uninstall, delete those files.

Settings live in `/usr/local/lib/podman-android/config`:

| Variable | Meaning | Default |
|---|---|---|
| `ROOTFS` | the chroot's path as Android sees it | set by `install.sh` |
| `JAIL_UID_MIN`, `JAIL_UID_MAX` | uid range for jailed containers | 4100-4999 |
| `JAIL_MEMORY` | memory limit of a jailed container | half of the phone's RAM |
| `JAIL_NPROC` | process and thread limit of a jailed container | 4096 |
| `NETGUARD_BLOCK4`, `NETGUARD_BLOCK6` | ranges containers are blocked from | private, link-local and carrier-internal ranges |

If you change the uid range, pick uids Android does not use. Apps use 10000 and up, and system uids are
scattered below that. A container running as such a uid has that account's rights on the phone.

## Run modes

| Command | Behavior | Use for |
|---|---|---|
| `podman`, `docker` | **jail mode**: own uid per container, no capabilities, read-only root, memory limit (half of the phone's RAM), process limit | default |
| `podman-trusted` | runs as the image specifies, usually root | trusted images that must start as root, such as the official `nginx` |

Both modes use a separate network namespace per container, set `no-new-privileges`, and add
blocking routes for private ranges, the phone's own addresses and its attached networks.
Containers can reach the internet but not the phone or the local network. Bridge and named
networks are not supported.

You can override jail options per container, for example `--read-only=false` or `--memory 2g`.

**Warning**: a container running as root through `podman-trusted` is only weakly isolated, about
the same as running the image as root on the phone.

## How it works

```
podman (wrapper, in the chroot)
  -> nsenter into its own mount namespace, which leaves the chroot
  -> lib/enter.sh (Android's shell, root): new private mount namespace, the chroot becomes
     its root, cgroup2 and a process-hiding /proc are mounted
  -> lib/dispatch (root, same namespace): adds the jail and build options, checks the network
  -> the real /usr/bin/podman
       -> lib/netguard (OCI hook): adds the blocking routes in the container's network namespace
```

All mounts happen in a private mount namespace and disappear when its last process exits.

## Stock Android kernel issues

| Missing in the kernel | Issue | Workaround |
|---|---|---|
| PID namespaces | the container sees every process on the phone | `/proc` in the container hides other uids' processes; each jailed container gets its own uid |
| User namespaces | a uid in the container is the same uid on the phone; no rootless mode | jail mode assigns an unused uid per container |
| IPC namespaces, SysV IPC | no IPC isolation; SysV shared memory unavailable | containers use `ipcns=host`; no workaround for SysV IPC |
| POSIX message queues | podman's default `/dev/mqueue` mount fails | a tmpfs is mounted there instead |
| cgroup pids controller | no process limit through cgroups | per-uid `nproc` ulimit in jail mode |
| cgroup device controller | no device filtering through cgroups | jailed containers get no capabilities |
| nftables | podman's bridge network does not work | slirp4netns; each container gets its own network namespace, the phone's firewall is untouched |
| overlay on f2fs | the overlay storage driver does not work | the vfs driver (see [Storage driver](#storage-driver)) |

## What was tested

| Feature | Result |
|---|---|
| `podman run`, published ports (`-p`) | works, also reachable from other hosts on the LAN |
| `podman run -it` | works in both modes |
| `podman exec`, `stop`, `start` | work |
| `podman build` | works |
| `podman-compose` | works in both modes without the bridge network: the first service gets `network_mode: slirp4netns`, the rest join it with `network_mode: "service:NAME"` (`examples/compose.yaml`). Compose files using the default network are refused |
| Pods | containers fail to start in a pod with an infra container; pods created by podman-compose work |
| Official `postgres` image | fails to start (no SysV IPC in the kernel) |

## Storage driver

podman uses the vfs driver, which copies the whole filesystem for every layer and takes about 3x
the disk space of fuse-overlayfs. fuse-overlayfs is not an option because `podman exec`,
`podman restart` and jail mode's `--read-only` fail with it.

## Limits

- **Jail mode needs images that run as a non-root user with a read-only root filesystem.**
  Images that require root (official `nginx`, most distribution images running services) need
  `podman-trusted` or an unprivileged image such as `nginxinc/nginx-unprivileged`.
- **Build steps are not isolated.** `RUN` executes as root, sees every process on the phone and
  can escalate privileges. Build only Containerfiles you trust.
- **Published ports listen on all of the phone's addresses.** To bind one address, name it:
  `-p 127.0.0.1:8080:8080`.
- **Do not grant containers `NET_ADMIN`.** With it, the blocking routes can be removed from
  inside the container.
- **Addresses the phone gets after a container starts are not blocked.**
- **Two containers started at the same moment can get the same uid**, in which case they see
  each other's processes and share one process limit.
- **Every podman command prints** `Failed to read current user namespace mappings`. It is
  harmless (the kernel has no user namespaces).
