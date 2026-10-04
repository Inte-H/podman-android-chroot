#!/bin/sh
# Reads a kernel configuration and tells whether this setup can work on it.
#   check-kernel.sh [config file]     default: /proc/config.gz
# Runs under Android's shell as well as inside the chroot. Exit status 1 when something
# required is missing.
cfg=${1:-/proc/config.gz}
[ -r "$cfg" ] || { echo "check-kernel: cannot read $cfg" >&2; exit 2; }
case $cfg in
  *.gz) rd="gzip -dc" ;;
  *) rd=cat ;;
esac
has() { $rd "$cfg" | grep -q "^CONFIG_$1=[ym]"; }
bad=0

echo "Required - without these the setup does not work:"
while read -r k why; do
  [ -n "$k" ] || continue
  if has "$k"; then echo "  ok       $k"; else echo "  MISSING  $k  ($why)"; bad=1; fi
done <<'LIST'
NAMESPACES namespaces at all
NET_NS a network namespace per container
UTS_NS a hostname per container
CGROUPS cgroup v2 for container bookkeeping
MEMCG the memory limit of jailed containers
SECCOMP_FILTER the system call filter
TUN slirp4netns networking
LIST

echo "Worked around - the setup expects these to be missing and does not need them:"
while read -r k how; do
  [ -n "$k" ] || continue
  if has "$k"; then echo "  present  $k  (its workaround is not needed on this kernel)"
  else echo "  absent   $k  -> $how"; fi
done <<'LIST'
PID_NS containers share the phone's process table; /proc hides other users' processes
USER_NS a uid in the container is the same uid on the phone; jail mode picks an unused one
IPC_NS containers.conf sets ipcns=host
SYSVIPC nothing replaces it: software that needs SysV shared memory does not start
POSIX_MQUEUE /dev/mqueue is a tmpfs
CGROUP_PIDS the process limit is a per-uid ulimit instead of a cgroup limit
CGROUP_DEVICE no device cgroup; jailed containers have no capability to create device nodes
NF_TABLES no bridge network; slirp4netns only
LIST

echo "Informational:"
for k in OVERLAY_FS FUSE_FS SECURITY_DEFEX SECURITY_SELINUX; do
  if has "$k"; then echo "  present  $k"; else echo "  absent   $k"; fi
done
[ $bad -eq 0 ] && echo "Result: the required features are there." || echo "Result: required features are missing."
exit $bad
