#!/bin/bash
# Checks an installed setup from inside the chroot: starts containers the way a user would and
# compares what they can see and do with what the setup promises. Leaves nothing behind.
#   IMAGE          image with a busybox userland   (default docker.io/library/alpine:latest)
#   PODMAN_ARGS    global podman options to pass along, for example a non-default hooks dir
#   PATH           decides which podman is checked; put the wrapper's directory first
IMAGE=${IMAGE:-docker.io/library/alpine:latest}
read -ra G <<<"${PODMAN_ARGS:-}"
lib=$(dirname "$(readlink -f "$(command -v podman)")")/../lib/podman-android
. "$lib/config"
fail=0
check() { # check "description" condition...
  if "${@:2}"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}
val() { sed -n "s/^$1=//p" <<<"$out"; }

probe='
echo uid=$(id -u)
echo caps=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status)
echo nnp=$(sed -n "s/^NoNewPrivs:[[:space:]]*//p" /proc/self/status)
echo netns=$(readlink /proc/self/ns/net)
echo procs=$(ls -d /proc/[0-9]* | wc -l)
touch /verify-write 2>/dev/null && echo rootfs=writable || echo rootfs=readonly
echo mem=$(cat "/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup)/memory.max" 2>/dev/null)
ip route show | grep -q ^unreachable && echo blocked=yes || echo blocked=no
wget -q -T 10 -O /dev/null http://example.com/ && echo internet=yes || echo internet=no
'
hostns=$(readlink /proc/self/ns/net)
hostprocs=$(ls -d /proc/[0-9]* | wc -l)

echo "podman run (jail):"
out=$(podman "${G[@]}" run --rm "$IMAGE" sh -c "$probe" </dev/null 2>&1)
uid=$(val uid)
check "runs at all" test -n "$uid"
check "uid $uid is inside $JAIL_UID_MIN-$JAIL_UID_MAX" test "${uid:-0}" -ge "$JAIL_UID_MIN" -a "${uid:-0}" -le "$JAIL_UID_MAX"
check "no capabilities" test "$(val caps)" = 0000000000000000
check "privilege escalation is off" test "$(val nnp)" = 1
check "root filesystem is read-only" test "$(val rootfs)" = readonly
check "own network namespace" test -n "$(val netns)" -a "$(val netns)" != "$hostns"
check "sees only its own processes ($(val procs) of $hostprocs)" test "$(val procs)" -le 5
check "memory limit is set ($(val mem))" test "$(val mem)" != max -a -n "$(val mem)"
check "private networks and the phone are unreachable" test "$(val blocked)" = yes
check "internet works" test "$(val internet)" = yes
[[ $fail == 0 ]] || { echo "--- output of the jailed container:"; echo "$out"; }

echo "podman-trusted run:"
out=$(podman-trusted "${G[@]}" run --rm "$IMAGE" sh -c "$probe" </dev/null 2>&1)
check "runs as the image's user (uid $(val uid))" test -n "$(val uid)"
check "privilege escalation is off" test "$(val nnp)" = 1
check "own network namespace" test -n "$(val netns)" -a "$(val netns)" != "$hostns"
check "private networks and the phone are unreachable" test "$(val blocked)" = yes
check "internet works" test "$(val internet)" = yes

echo "bridge networks are refused before a device is created:"
podman "${G[@]}" run --rm --network bridge "$IMAGE" true </dev/null >/dev/null 2>&1
check "refused with status 125" test $? = 125

echo "nothing left behind:"
check "no containers" test -z "$(podman "${G[@]}" ps -aq </dev/null 2>/dev/null)"
check "no conmon, slirp4netns or rootlessport processes" test -z "$(pgrep -x 'conmon|slirp4netns|rootlessport')"
check "no bridge or veth devices" test -z "$(ip -o link show type bridge; ip -o link show type veth)"

[[ $fail == 0 ]] && echo "Result: all checks passed." || echo "Result: some checks FAILED."
exit $fail
