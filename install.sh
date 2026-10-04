#!/bin/bash
# Installs podman-android into the chroot it is run from. Run it as root inside the chroot.
#   PREFIX   where bin/ and lib/ go          (default /usr/local)
#   ETCDIR   podman's configuration folder   (default /etc/containers)
#   ROOTFS   the chroot's path seen from Android; detected when not given
# Existing files in ETCDIR are kept; compare them with etc/ by hand.
set -eu
PREFIX=${PREFIX:-/usr/local}
ETCDIR=${ETCDIR:-/etc/containers}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lib=$PREFIX/lib/podman-android

((EUID == 0)) || { echo "install.sh: run as root inside the chroot" >&2; exit 1; }
for b in /usr/bin/podman crun conmon slirp4netns ip nsenter pivot_root pgrep awk; do
  command -v "$b" >/dev/null || { echo "install.sh: $b is missing (install podman, crun, slirp4netns, iproute2, procps)" >&2; exit 1; }
done

# Entering our own mount namespace again leaves the chroot; from there this shell's root
# directory reads as the chroot's real path
ROOTFS=${ROOTFS:-$(nsenter --mount=/proc/self/ns/mnt /system/bin/readlink "/proc/$$/root")}
[[ -n $ROOTFS && $ROOTFS != / ]] ||
  { echo "install.sh: could not detect the chroot path; pass ROOTFS=..." >&2; exit 1; }

install -d "$PREFIX/bin" "$lib/empty" "$ETCDIR/oci/hooks.d"
install -m 755 "$src/bin/podman" "$PREFIX/bin/podman"
install -m 755 "$src/lib/enter.sh" "$src/lib/dispatch" "$src/lib/netguard" "$lib/"
ln -sfn podman "$PREFIX/bin/docker"
ln -sfn podman "$PREFIX/bin/podman-trusted"
if [[ -e $lib/config ]]; then
  echo "kept      $lib/config"
else
  sed -e "s|^ROOTFS=.*|ROOTFS=$ROOTFS|" -e "s|^HOOKS_DIR=.*|HOOKS_DIR=$ETCDIR/oci/hooks.d|" \
    "$src/lib/config" > "$lib/config"
fi

for f in containers.conf storage.conf; do
  if [[ -e $ETCDIR/$f ]]; then
    echo "kept      $ETCDIR/$f"
  else
    sed "s|/etc/containers/oci/hooks.d|$ETCDIR/oci/hooks.d|" "$src/etc/$f" > "$ETCDIR/$f"
  fi
done
cat > "$ETCDIR/oci/hooks.d/podman-android-netguard.json" <<JSON
{
  "version": "1.0.0",
  "hook": { "path": "$lib/netguard" },
  "when": { "always": true },
  "stages": ["createRuntime"]
}
JSON

echo "installed $PREFIX/bin/{podman,docker,podman-trusted} and $lib (ROOTFS=$ROOTFS)"
echo "next: tools/verify.sh"
