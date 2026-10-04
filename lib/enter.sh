#!/system/bin/sh
# Prepares a place inside an Android chroot where podman can run, then runs a command there.
# Start it as root from the top of the mount namespace (the Android root, not the chroot).
#   enter.sh --rootfs DIR [--cwd DIR] command [args...]
# Everything is mounted in a private mount namespace, so it all disappears when the last
# process in that namespace exits. Nothing ever has to be unmounted by hand.
if [ "$1" != --stage2 ]; then
  exec /system/bin/unshare -m /system/bin/sh "$0" --stage2 "$@"
fi
shift
[ "$1" = --rootfs ] && [ -d "$2" ] || { echo "enter.sh: --rootfs DIR is required" >&2; exit 96; }
R=$2; shift 2
cwd=/
if [ "$1" = --cwd ]; then cwd=$2; shift 2; fi

# Make the chroot directory the root of this namespace. A plain chroot is not enough: "/" is
# then not a mount point, so unpacking images fails, and podman exec lands in the Android
# root. The old root stays reachable under /mnt.
# Android's shell cannot run the distro's binaries before the pivot, so pivot_root is started
# through the distro's own dynamic loader.
L=$R/usr/lib/$(uname -m)-linux-gnu
for LD in "$L"/ld-linux-*.so.*; do break; done
for PIVOT in "$R/usr/sbin/pivot_root" "$R/usr/bin/pivot_root"; do [ -x "$PIVOT" ] && break; done
[ -x "$LD" ] && [ -x "$PIVOT" ] ||
  { echo "enter.sh: no dynamic loader in $L or no pivot_root in the chroot" >&2; exit 96; }
mount -o rbind "$R" "$R" || exit 96
cd "$R" || exit 96
"$LD" --library-path "$L" "$PIVOT" . mnt || exit 96
cd / || exit 96
# From here on this is the distro root; /system/bin is gone from the path
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH

# The chroot's /sys has no cgroup filesystem
mount -t cgroup2 none /sys/fs/cgroup || exit 96

# A /proc that hides other users' processes. containers.conf puts it over the container's /proc
mkdir -p /run/podman-proc && mount -t proc -o hidepid=2 proc /run/podman-proc || exit 96

# /run is on disk here, so runtime state survives a reboot. Drop it when the boot changed
boot=$(cat /proc/sys/kernel/random/boot_id)
mark=/var/lib/containers/.boot_id
if [ "$(cat $mark 2>/dev/null)" != "$boot" ]; then
  rm -rf /run/libpod /run/containers /run/crun
  mkdir -p /var/lib/containers && echo "$boot" > $mark
fi

cd "$cwd" 2>/dev/null || cd /
exec /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 \
  PODMAN_IGNORE_CGROUPSV1_WARNING=1 \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
