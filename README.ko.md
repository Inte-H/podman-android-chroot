# podman-android-chroot

English: [README.md](README.md)

루팅한 안드로이드 폰의 리눅스 chroot 안에서 podman 컨테이너를 돌립니다. 커널은 **순정 그대로**
씁니다. 커스텀 커널이 필요 없고, 폰의 방화벽 규칙·경로·네트워크 장치에 아무것도 더하지 않습니다.
`podman run`만 쳐도 컨테이너가 가둬진 상태로 뜹니다.

**상태: 초안.** 아래 내용은 모두 폰 한 대에서 측정한 것입니다.

| | |
|---|---|
| 폰 | 삼성 갤럭시 S26 울트라, 순정 펌웨어, KernelSU로 루팅 |
| 커널 | 6.12.30 (android16 GKI, 삼성 빌드), arm64, 페이지 크기 4KB |
| chroot | Termux의 chroot-distro로 설치한 Ubuntu 26.04, `/data`는 f2fs |
| 소프트웨어 | podman 5.7.0, crun, slirp4netns, podman-compose 1.5.0 |

다른 폰, 다른 루팅 방식, 다른 배포판에서는 시험하지 않았습니다.

## 순정 안드로이드 커널에 없는 것

| 커널에 없는 기능 | 그래서 생기는 일 | 이 구성의 대응 |
|---|---|---|
| PID 네임스페이스 | 컨테이너가 폰의 프로세스 목록을 같이 본다 | 컨테이너의 `/proc`에서 다른 사용자의 프로세스를 가리고, jail 컨테이너마다 사용자 번호를 따로 준다 |
| 사용자 네임스페이스 | 컨테이너 안의 사용자 번호가 곧 폰의 번호다. rootless 모드도 없다 | jail 모드가 컨테이너마다 안 쓰는 번호를 고른다 |
| IPC 네임스페이스, SysV IPC | IPC를 따로 떼어 줄 수 없고, SysV 공유 메모리가 필요한 프로그램은 뜨지 않는다 | `ipcns = host`로 둔다. SysV IPC를 대신할 방법은 없다 |
| POSIX 메시지 큐 | podman이 기본으로 붙이는 `/dev/mqueue`가 실패한다 | 그 자리에 tmpfs를 붙인다 |
| cgroup의 pids 컨트롤러 | cgroup으로 프로세스 수를 제한할 수 없다 | jail 모드에서 사용자 번호별 `nproc` ulimit을 건다 |
| cgroup의 device 컨트롤러 | cgroup으로 장치 접근을 거를 수 없다 | jail 컨테이너에는 권한(capability)을 하나도 주지 않는다 |
| nftables | podman의 브리지 네트워크가 실패한다 | slirp4netns를 쓴다. 폰의 방화벽을 건드리지 않고 컨테이너에 전용 네트워크 네임스페이스를 준다 |
| f2fs 위의 overlay | overlay 저장 방식이 실패한다 | vfs 저장 방식을 쓴다([저장 방식](#저장-방식) 참고) |

네트워크·UTS 네임스페이스, 메모리 컨트롤러가 있는 cgroup v2, seccomp, TUN은 커널에 있어서 그대로
씁니다. `tools/check-kernel.sh`가 같은 목록으로 커널을 확인해 줍니다.

## 명령은 두 가지

| 명령 | 컨테이너가 도는 모습 | 쓰는 곳 |
|---|---|---|
| `podman`, `docker` | **가둔 상태**: 컨테이너마다 안 쓰는 사용자 번호, 권한 없음, 읽기 전용 루트, 메모리 한도(폰 전체의 절반), 프로세스 수 한도 | 기본값. 특별한 이유가 없으면 이쪽 |
| `podman-trusted` | 이미지가 정한 대로, 대개 root | 공식 `nginx`처럼 root로만 시작하는, 믿을 수 있는 이미지 |

두 명령 모두 컨테이너에 전용 네트워크 네임스페이스를 주고, 권한 상승을 막고(`no-new-privileges`),
컨테이너 안에 사설망 대역·폰 자신의 주소·폰이 붙어 있는 망으로 가는 "갈 수 없음" 경로를 넣습니다.
그래서 컨테이너는 인터넷에는 나가지만 폰과 주변 기기에는 닿지 못합니다. 브리지나 이름 붙인
네트워크를 지정하면, podman이 폰에 브리지 장치를 만들기 전에 거절합니다.

jail 옵션은 사용자가 준 옵션보다 앞에 놓이므로 컨테이너 하나만 따로 바꿀 수 있습니다. 예를 들면
`podman run --read-only=false ...`, `--memory 2g`.

**얼마나 단단한가.** jail 컨테이너는 우리가 시도한 범위에서 한 번도 뚫리지 않았습니다.
`podman-trusted`로 root로 도는 컨테이너는 가두는 힘이 약합니다. 그 이미지를 폰에서 root로 실행하는
것과 같다고 보고, 믿는 이미지에만 쓰십시오. 이 문서에는 결론만 적습니다.

## 설치

chroot 안에서 root로 실행합니다.

```sh
apt install podman crun slirp4netns iproute2 procps    # compose를 쓰려면 podman-compose도
sh tools/check-kernel.sh        # /proc/config.gz를 읽는다
bash install.sh
bash tools/verify.sh
```

`install.sh`는 `podman`, `docker`, `podman-trusted`를 `/usr/local/bin`에, 스크립트를
`/usr/local/lib/podman-android`에, `containers.conf`·`storage.conf`·OCI 훅 하나를
`/etc/containers`에 둡니다. `/etc/containers`에 이미 있는 파일은 그대로 두니 `etc/`의 내용과 직접
비교해서 맞추십시오. 위치는 `PREFIX`, `ETCDIR`로 바꿀 수 있습니다. 지울 때는 이 파일들을 삭제하면
됩니다.

설정은 `/usr/local/lib/podman-android/config`에 있습니다.

| 변수 | 뜻 | 기본값 |
|---|---|---|
| `ROOTFS` | 안드로이드에서 본 chroot의 경로 | `install.sh`가 찾아 넣는다 |
| `SU` | root가 아닌 사용자가 root로 올라가는 방법(`su` 실행 파일 또는 `sudo`) | `/system/bin/su` |
| `JAIL_UID_MIN`, `JAIL_UID_MAX` | jail 컨테이너에 줄 사용자 번호 범위 | 4100~4999 |
| `JAIL_MEMORY` | jail 컨테이너의 메모리 한도 | 폰 전체의 절반 |
| `JAIL_NPROC` | jail 컨테이너의 프로세스·스레드 수 한도 | 4096 |
| `NETGUARD_BLOCK4`, `NETGUARD_BLOCK6` | 컨테이너가 닿으면 안 되는 대역 | 사설망, 링크 로컬, 통신사 내부망 |

사용자 번호 범위는 안드로이드가 쓰지도 막지도 않는 구간이어야 합니다. 시험한 폰에서는 앱이 없는
10000번 이상 번호로는 소켓을 열 수 없었고, 4000번대는 비어 있었습니다.

## 시험한 것

시험한 폰에서 `tools/verify.sh`를 돌린 결과입니다.

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

| 기능 | 결과 |
|---|---|
| `podman run`, 포트 공개(`-p`) | 된다. root가 아닌 nginx가 폰에서도, 같은 망의 다른 기기에서도 HTTP 200으로 응답했다 |
| `podman run -it` | 두 모드 모두 된다(터미널이 잡히고 입력과 출력이 오간다) |
| `podman exec`, `stop`, `start` | 된다 |
| `podman build` | 된다. 래퍼가 `--network=slirp4netns`를 넣고 `/dev/mqueue`를 덮어 준다. 이 둘이 없으면 빌드가 실패한다 |
| `podman-compose` | 서비스가 브리지 네트워크를 쓰지 않게 하면 두 모드 모두 된다. 첫 서비스에 `network_mode: slirp4netns`를 주고 나머지는 `network_mode: "service:이름"`으로 거기에 합류시킨다(`examples/compose.yaml`). 기본 네트워크를 쓰는 compose 파일은 거절된다 |
| pod | `podman pod create`는 되지만, infra 컨테이너가 있는 pod 안에서는 컨테이너가 뜨지 않는다(`"/dev/mqueue": duplicate mount destination`). podman-compose가 만드는 pod는 infra 컨테이너가 없어서 문제없다 |
| 공식 `postgres` 이미지 | 뜨지 않는다. `shmget: Function not implemented`(커널에 SysV IPC가 없음) |

## 저장 방식

vfs 저장 방식은 마운트가 필요 없어서 이 환경에서 동작하지만, 레이어마다 그리고 컨테이너마다
파일시스템 전체를 복사해 둡니다. nginx 이미지 두 개(64MB, 56MB)가 디스크에서 315MB를 차지하고,
레이어가 많은 이미지는 훨씬 더 커집니다.

대안으로 fuse-overlayfs를 시험했습니다. 같은 이미지 두 개가 111MB였고 이미지 받기, 실행, 빌드,
`stop`, `start`가 됐습니다. 그래도 **적용하지 않았습니다.** 이 구성은 podman을 부를 때마다 전용
마운트 네임스페이스를 새로 만들고, 그 안의 마지막 프로세스가 끝나면 네임스페이스도 사라지게 되어
있는데, 이 구조에서는 세 가지가 깨지기 때문입니다.

- 나중에 부른 `podman exec`를 삼성 커널의 DEFEX 보호 기능이 죽인다.
- `podman restart`가 실패한다. 컨테이너의 파일시스템이 그 컨테이너를 띄운 호출의 네임스페이스에만
  붙어 있어서다.
- jail 모드가 쓰는 `--read-only`가 `set xattr ... Permission denied`로 실패한다. 읽기 전용일 때
  자동으로 붙는 tmpfs를 꺼야 뜬다.

나중 호출이 떠 있는 컨테이너의 마운트 네임스페이스에 합류하면 `exec`와 `restart`가 됩니다. 곧
네임스페이스를 함께 쓰도록 구조를 바꾸면 fuse-overlayfs를 쓸 수 있습니다. 그 작업은 이 초안에
들어 있지 않습니다.

## 한계

- **jail 모드에는 root가 아닌 사용자와 읽기 전용 루트로 도는 이미지가 필요합니다.** root를 고집하는
  이미지(공식 `nginx`, 서비스를 띄우는 대부분의 배포판 이미지)는 `podman-trusted`로 돌리거나
  `nginxinc/nginx-unprivileged` 같은 비특권 판을 쓰십시오.
- **빌드 단계는 가둬지지 않습니다.** `RUN`은 root로 실행되고, 폰의 프로세스 목록 전체를 보며, 권한
  상승도 막혀 있지 않습니다. 믿는 Containerfile만 빌드하십시오.
- **공개한 포트는 폰의 모든 주소에서 열립니다.** 주소를 지정하면 그 주소에서만 열립니다
  (`-p 127.0.0.1:8080:8080`).
- **컨테이너에 `NET_ADMIN`을 주지 마십시오.** 주면 차단 경로를 안에서 지울 수 있습니다.
- **오래 떠 있는 컨테이너는 새 주소를 모릅니다.** 차단 경로는 컨테이너가 뜰 때 계산합니다. 그 뒤에
  폰이 새로 받은 주소는 들어가지 않습니다.
- **root가 아닌 사용자에서 올라가는 경로는 확인하지 못했습니다.** 시험한 폰에서는 root 셸에서
  래퍼를 썼습니다. chroot 안의 일반 사용자에서는 안드로이드의 `su`가 실행되지 않았고(`/apex` 아래의
  안드로이드 로더가 chroot에서 보이지 않음), `sudo`는 삼성 DEFEX가 죽였습니다.
- **같은 순간에 띄운 두 컨테이너가 같은 사용자 번호를 받을 수 있습니다.** 번호는 범위 안에서
  무작위로 고르고 미리 잡아 두지 않습니다. 겹치면 두 컨테이너가 서로의 프로세스를 보고 프로세스 수
  한도도 함께 셉니다.
- **podman 명령마다** `Failed to read current user namespace mappings` 경고가 나옵니다. 커널에
  사용자 네임스페이스가 없어서 나오는 것으로, 동작에는 영향이 없습니다.
- arm64 이미지만 돌려 봤습니다. 다른 아키텍처용 이미지는 시험하지 않았습니다.

## 동작 방식

```
podman (chroot 안의 래퍼)
  -> nsenter로 자기 마운트 네임스페이스에 다시 들어간다. 이때 chroot 밖으로 나간다
  -> lib/enter.sh (안드로이드 셸, root): 전용 마운트 네임스페이스를 만들고, chroot를 그 최상위로
     올리고, cgroup2와 프로세스를 가린 /proc을 붙인다
  -> lib/dispatch (root, 그 네임스페이스 안): jail 옵션과 빌드 옵션을 넣고 네트워크를 검사한다
  -> 진짜 /usr/bin/podman
```

모든 마운트는 전용 마운트 네임스페이스 안에서 이루어지고, 그 안의 마지막 프로세스가 끝나면 함께
사라집니다. 손으로 풀어야 할 마운트가 없고, 안드로이드 쪽은 아무것도 바뀌지 않습니다.
`lib/netguard`는 OCI 훅으로, 컨테이너마다 그 네트워크 네임스페이스 안에 차단 경로를 넣습니다.
