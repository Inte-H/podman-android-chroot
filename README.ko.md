# podman-android-chroot

English: [README.md](README.md)

루팅한 안드로이드 폰의 리눅스 chroot 안에서 순정 커널로 podman 컨테이너를 돌립니다.

## 테스트 환경

| | |
|---|---|
| 폰 | 삼성 갤럭시 S26 울트라, 순정 펌웨어, KernelSU로 루팅 |
| 커널 | 6.12.30 (android16 GKI, 삼성 빌드), arm64, 페이지 크기 4KB |
| chroot | Termux의 chroot-distro로 설치한 Ubuntu 26.04, `/data`는 f2fs |
| 소프트웨어 | podman 5.7.0, crun, slirp4netns, podman-compose 1.5.0 |

## 설치

설치와 `podman` 실행 모두 chroot 안의 root 셸에서 합니다.

1. 패키지 설치(compose를 쓰려면 `podman-compose`도 추가)

   ```sh
   apt install podman crun slirp4netns iproute2 procps
   ```

2. 커널에 필요한 기능이 있는지 확인

   ```sh
   sh tools/check-kernel.sh
   ```

3. 설치

   ```sh
   bash install.sh
   ```

4. 격리가 제대로 되는지 확인(항목마다 PASS 또는 FAIL 출력)

   ```sh
   bash tools/verify.sh
   ```

`install.sh`는 `podman`, `docker`, `podman-trusted`를 `/usr/local/bin`에, 스크립트를
`/usr/local/lib/podman-android`에, `containers.conf`·`storage.conf`·OCI 훅 하나를
`/etc/containers`에 설치합니다. 이미 있는 파일은 덮어쓰지 않으니 `etc/`와 비교해 직접 반영하십시오.
설치 위치는 `PREFIX`, `ETCDIR`로 바꿀 수 있고, 제거는 이 파일들을 삭제하면 됩니다.

설정은 `/usr/local/lib/podman-android/config`에 있습니다.

| 변수 | 뜻 | 기본값 |
|---|---|---|
| `ROOTFS` | 안드로이드 기준 chroot 경로 | `install.sh`가 자동 설정 |
| `JAIL_UID_MIN`, `JAIL_UID_MAX` | jail 컨테이너에 할당할 UID 범위 | 4100~4999 |
| `JAIL_MEMORY` | jail 컨테이너 메모리 제한 | 폰 전체의 절반 |
| `JAIL_NPROC` | jail 컨테이너 프로세스·스레드 수 제한 | 4096 |
| `NETGUARD_BLOCK4`, `NETGUARD_BLOCK6` | 컨테이너에서 접근을 막을 대역 | 사설망, 링크 로컬, 통신사 내부망 |

UID 범위는 10000 미만으로 두십시오. 10000 이상은 안드로이드 앱이 쓰는 대역입니다.

## 실행 모드

| 명령 | 동작 | 용도 |
|---|---|---|
| `podman`, `docker` | **jail 모드**: 컨테이너마다 별도 UID, capability 없음, 읽기 전용 루트, 메모리 제한(폰 전체의 절반), 프로세스 수 제한 | 기본 |
| `podman-trusted` | 이미지 설정대로 실행(대개 root) | 공식 `nginx`처럼 root로 시작해야 하는 신뢰할 수 있는 이미지 |

두 명령 모두 컨테이너마다 별도 network namespace를 쓰고, 권한 상승을 막고(`no-new-privileges`),
사설망 대역·폰 자신의 주소·폰이 연결된 망으로 가는 unreachable route를 넣습니다. 컨테이너는
인터넷에만 나갈 수 있고 폰과 주변 기기에는 접근할 수 없습니다. bridge나 named network는
쓸 수 없습니다.

jail 옵션은 컨테이너별로 덮어쓸 수 있습니다. 예: `podman run --read-only=false ...`, `--memory 2g`.

**주의**: `podman-trusted`로 root로 실행한 컨테이너는 격리 수준이 낮습니다. 그 이미지를 폰에서 직접 root로
실행하는 것과 비슷하다고 보고, 신뢰할 수 있는 이미지에만 쓰십시오.

## 동작 방식

```
podman (chroot 안의 wrapper)
  -> nsenter로 자기 mount namespace에 다시 들어감 (chroot 밖으로 나감)
  -> lib/enter.sh (안드로이드 셸, root): private mount namespace 생성, chroot를 그 root로 지정,
     cgroup2와 프로세스를 숨긴 /proc mount
  -> lib/dispatch (root, 같은 namespace): jail 옵션·빌드 옵션 추가, 네트워크 검사
  -> 실제 /usr/bin/podman
       -> lib/netguard (OCI 훅): 컨테이너 network namespace에 차단 route 추가
```

모든 mount는 private mount namespace 안에서만 이뤄지고 마지막 프로세스가 끝나면 사라집니다.

## 순정 안드로이드 커널 이슈

| 커널에 없는 기능 | 이슈 | 대응 |
|---|---|---|
| PID 네임스페이스 | 컨테이너에서 폰의 프로세스가 다 보임 | 컨테이너 `/proc`에서 다른 UID의 프로세스를 숨김, jail 컨테이너마다 UID 따로 할당 |
| 사용자 네임스페이스 | 컨테이너 UID가 폰의 UID와 같음, rootless 불가 | jail 모드에서 컨테이너마다 비어 있는 UID 할당 |
| IPC 네임스페이스, SysV IPC | IPC 격리 불가, SysV 공유 메모리를 쓰는 프로그램은 실행 안 됨 | `ipcns = host`, SysV IPC는 대안 없음 |
| POSIX 메시지 큐 | podman 기본 `/dev/mqueue` 마운트 실패 | 그 자리에 tmpfs 마운트 |
| cgroup pids 컨트롤러 | cgroup으로 프로세스 수 제한 불가 | jail 모드에서 UID별 `nproc` ulimit 적용 |
| cgroup device 컨트롤러 | cgroup으로 장치 접근 제한 불가 | jail 컨테이너는 capability 전부 제거 |
| nftables | podman 브리지 네트워크 사용 불가 | slirp4netns 사용, 폰 방화벽은 건드리지 않고 컨테이너마다 네트워크 네임스페이스 분리 |
| f2fs 위 overlay | overlay 스토리지 드라이버 사용 불가 | vfs 드라이버 사용([스토리지 드라이버](#스토리지-드라이버) 참고) |

## 시험한 것

| 기능 | 결과 |
|---|---|
| `podman run`, 포트 공개(`-p`) | 정상. 같은 망의 다른 기기에서도 접속 가능 |
| `podman run -it` | 두 모드 모두 정상 |
| `podman exec`, `stop`, `start` | 정상 |
| `podman build` | 정상 |
| `podman-compose` | 브리지 네트워크를 쓰지 않으면 두 모드 모두 정상. 첫 서비스에 `network_mode: slirp4netns`, 나머지는 `network_mode: "service:이름"`으로 첫 서비스에 합류(`examples/compose.yaml`). 기본 네트워크를 쓰는 compose 파일은 거부 |
| pod | infra 컨테이너가 있는 pod에서는 컨테이너 실행 실패. podman-compose가 만드는 pod는 정상 |
| 공식 `postgres` 이미지 | 실행 실패(커널에 SysV IPC 없음) |

## 스토리지 드라이버

vfs는 레이어마다 파일시스템을 통째로 복사해 디스크를 fuse-overlayfs의 약 3배 차지합니다.
fuse-overlayfs는 이 구성에서 `podman exec`, `podman restart`, jail 모드의 `--read-only`가 실패해
적용할 수 없습니다.

## 한계

- **jail 모드는 non-root 사용자와 read-only root filesystem으로 실행되는 이미지가 필요합니다.** root가
  필요한 이미지(공식 `nginx`, 서비스용 배포판 이미지 대부분)는 `podman-trusted`로 실행하거나
  `nginxinc/nginx-unprivileged` 같은 unprivileged 이미지를 쓰십시오.
- **빌드 단계는 격리되지 않습니다.** `RUN`은 root로 실행되고, 폰의 전체 프로세스가 보이며, 권한 상승도
  막지 않습니다. 신뢰할 수 있는 Containerfile만 빌드하십시오.
- **공개한 포트는 폰의 모든 주소에서 열립니다.** 특정 주소만 열려면 `-p 127.0.0.1:8080:8080`처럼
  지정하십시오.
- **컨테이너에 `NET_ADMIN`을 부여하지 마십시오.** 부여하면 컨테이너 안에서 차단 route를 지울 수 있습니다.
- **컨테이너 실행 후 폰이 받은 새 주소는 차단되지 않습니다.**
- **동시에 시작한 두 컨테이너가 같은 UID를 받을 수 있습니다.** 겹치면 서로의 프로세스가 보이고 프로세스
  수 제한도 함께 적용됩니다.
- **podman 명령마다** `Failed to read current user namespace mappings` 경고가 나오지만 동작에는 영향이
  없습니다(커널에 user namespace 없음).
