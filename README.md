# cloud-image

基于 GitHub Actions 自动构建适用于 **Proxmox VE (PVE)** 的 Linux Cloud Image，方便 PVE 侧自动下载。构建配置已矩阵化，新增发行版只需在矩阵里加一行配置。

## 构建流程

1. 从官方源下载云镜像并校验 checksum
2. `qemu-nbd` 挂载 → **chroot 原生包管理定制**（Debian 系用 apt，RHEL 系用 dnf/yum；不使用 TCG/虚拟机模拟，构建速度快）；需要 ESP 的条目（目前只有 CentOS 7）在这一步之前追加 ESP
3. 压缩为 qcow2，并做一次启动测试（RHEL 系默认开启，Debian 系默认关闭；`BOOT_TEST=true/false` 可强制）
4. `release` job 合并所有版本的镜像，按日期发布单个 Release

每次构建会产生以下镜像（`config/images.yaml` 里的 8 个条目）：

- `debian-12-pve-sunoaki+YYYYMMDD.qcow2`
- `debian-13-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-22.04-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-24.04-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-26.04-pve-sunoaki+YYYYMMDD.qcow2`
- `rocky-9-pve-sunoaki+YYYYMMDD.qcow2`
- `rocky-10-pve-sunoaki+YYYYMMDD.qcow2`
- `centos-7-pve-sunoaki+YYYYMMDD.qcow2`（`frozen: true`，只在手动触发时构建）

Release tag 为 `YYYYMMDD`；同一天重复构建会先删除当天的旧 Release 再发布新版本。
`frozen: true` 的条目在定时构建里被跳过，因为上游内容已冻结，重建只会产生内容相同、日期不同的产物。
`efi_esp: true` 的条目会在构建时得到一个 ESP，用于上游只提供 BIOS 引导的发行版，目前只有 CentOS 7。

## 镜像定制内容

共用步骤对两个发行版家族都执行，差异部分由 `scripts/family/<family>.sh` 提供。

- **时区** `Asia/Hong_Kong`；NTP 源追加 `time.apple.com`（Debian 系写 `systemd-timesyncd`，并在同一行加 `time.windows.com`；RHEL 系写 `chrony`，只加 `time.apple.com`）
- **GRUB** 在 `/etc/default/grub` 里设 `GRUB_DISABLE_OS_PROBER=true`（避免 loopback 探测导致无法启动）；启用 `serial-getty@ttyS1` 串口登录。若某衍生版没有 `/etc/default/grub`，这一步只告警并跳过，不中断构建
- **安全提示**写入 `/etc/motd.d/99-pve-security`，并镜像进 `/etc/motd`。RHEL 系镜像的 `/etc/pam.d/{login,sshd}` 原本不调用 `pam_motd`，脚本会补上该行，否则提示没有机会显示
- **root 密码登录**：cloud-init `disable_root: false`、`ssh_pwauth: true`，sshd `PermitRootLogin yes`，并在 `/etc/ssh/sshd_config` 补 `Include /etc/ssh/sshd_config.d/*.conf`（CentOS 7 自身没有这一行，缺了 drop-in 就是空转）。RHEL 系的默认用户由 `rocky` / `centos` 改名为 `root`，与 Ubuntu 的做法一致
- **cloud-init** 关闭启动时重新生成包源；Debian 系另去掉 `deb-src`（DEB822 与旧式 `sources.list` 两种格式均处理），并写 `/etc/cloud/cloud.cfg.d/99-pve-apt.cfg` 设置 `apt.preserve_sources_list: true` 以保留 PVE 下发的源（用嵌套写法，旧的顶层 `apt_preserve_sources_list` 已在 cloud-init 22.1 弃用）
- **SELinux**（仅 RHEL 系）：GitHub runner 的内核无法写 `security.selinux` 扩展属性（实测即使 uid 0 且拥有全部 capability 也是 EPERM），因此构建期无法重新打标。做法是首次启动设为 permissive 并写 `/.autorelabel`，由 `selinux-autorelabel` 重标后经一个 oneshot 单元恢复 enforcing 并删除标记
- **内核调优**：见下文，按家族使用不同模板
- **清理**：删除 `/var/log/*.log`、清空 `/tmp` 与 `/etc/machine-id`

按家族不同的部分：

| 类别 | Debian 系（`debian.sh`） | RHEL 系（`rhel.sh`） |
| --- | --- | --- |
| 包管理 | `apt-get` | `dnf`（CentOS 7 上是 Python 转发到 `yum`） |
| 引导器更新 | `update-grub` | `grub2-mkconfig` |
| sshd 单元名 | `ssh` | `sshd` |
| NTP 守护进程 | `systemd-timesyncd` | `chrony` |
| SELinux 重标 | 空操作 | permissive + `/.autorelabel` + oneshot 恢复 |
| 包列表 | `config/packages-deb.txt` | `config/packages-rpm.txt`，CentOS 7 用 `config/packages-rpm-centos7.txt` |
| sysctl 模板 | `config/sysctl-debian.conf` | `config/sysctl-rhel.conf` |
| 默认用户名 | `ubuntu` | `rocky` / `centos` |
| EOL 提示 | 空操作 | 仅 CentOS 7，写 `/etc/motd.d/98-pve-eol` |

RHEL 系的包列表**有意小于** Debian 系：`aria2 most screen htop` 不在 BaseOS/AppStream，取它们需要引入 EPEL 及其 GPG 信任链；CentOS 7 另缺 `zstd` 与 `lldpd`（`zstd` 在 CentOS 7 与 EPEL 7 都不存在，`lldpd` 只在 EPEL 7），因此镜像内不启用 EPEL。

内核调优模板安装为 `/etc/sysctl.d/99-pve-cloud-tuning.conf`，按「直连公网 IP、无 NAT、回程路径可能不对称、磁盘为 Ceph RBD 上的 virtio-scsi」这一使用场景取值。两个模板共有的项目：

| 项目 | 值 | 说明 |
| --- | --- | --- |
| `net.core.somaxconn` | `8192` | 突发入向连接的 accept/syn 积压 |
| `net.ipv4.tcp_max_syn_backlog` | `8192` | 同上 |
| `net.ipv4.ip_local_port_range` | `32768 65535` | 临时端口上界由 60999 提到 65535，低段不动，避开租户自用端口 |
| `net.core.rmem_max` / `wmem_max` | `16777216` | 自动调优的上界，适配高带宽时延积链路 |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 … 16777216` | 同上 |
| `net.ipv4.conf.{all,default}.rp_filter` | `2` | 宽松模式，多公网 IP 与不对称回程下严格模式会静默丢包 |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood 防护 |
| `fs.aio-max-nr` | `1048576` | virtio-scsi 队列在高 IOPS 下会耗尽默认 64k aio 池 |
| `vm.dirty_background_ratio` / `vm.dirty_ratio` | `5` / `10` | 平滑回写，避免 RBD 磁盘上的脏页堆积 |
| `vm.swappiness` | `10` | 保留热页，减少数据库换页 |
| `vm.max_map_count` | `1048576` | 数据库/中间件类负载 |
| `fs.file-max` | `2097152` | 同上 |
| `fs.inotify.max_user_watches` | `524288` | 同上 |

RHEL 模板**不含** `net.core.default_qdisc=fq`、`tcp_congestion_control=bbr`、`tcp_slow_start_after_idle`、`tcp_fastopen` 四项。原因不是统一取舍：Rocky 9/10 的内核足够新，而 CentOS 7 运行 3.10，其内核配置里没有 `CONFIG_TCP_CONG_BBR`、也没有 `fq` qdisc，systemd 219 更不会读 `/etc/modules-load.d`。写入这些项会显示成已生效的调优，实际无效，因此按家族分文件而不是共用一份。

CentOS 7 已 EOL（2024-06-30），其仓库在构建时改写指向 `vault.centos.org/7.9.2009/{os,updates,extras}`，因为 `mirrorlist.centos.org` 已不再解析（实测 NXDOMAIN），不改写连装包都无法完成。镜像内 `/etc/motd.d/98-pve-eol` 会说明这一状态。

> **安全提示**：镜像里的 root 密码默认是**锁定**的（`/etc/shadow` 中为 `*`，实测空密码无法通过串口或 SSH 登录），但镜像已放开 `PermitRootLogin yes`、`ssh_pwauth: true`、`disable_root: false`，各家族的默认用户也被改名为 `root`。因此一旦用 PVE cloud-init 给 root 下发密码，密码登录立即可用——且 Release 是公开可下载的。请只在受控网络（内网 / 安全组限制来源 IP）里使用这些模板；对外暴露前请改用密钥认证并在 PVE 侧关闭密码登录。

## 触发构建

在 GitHub Actions 页面手动运行（`workflow_dispatch`），或：

```bash
gh workflow run build-cloud-image.yml
```

## 在 PVE 中使用

下载最新 Release（PVE 节点上需先配置 `gh` 或直接用 GitHub API）：

```bash
TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
gh release download "$TAG" --pattern 'debian-13-*.qcow2' # 或 ubuntu-24.04-*.qcow2
```

创建模板（注意：Debian cloud 镜像没有 AHCI 驱动，cloud-init 盘**必须用 `--scsi2`，不能用 `--ide2`**）：

```bash
qm create 9000 --name debian-13-cloud --memory 2048 --net0 virtio,bridge=vmbr0
qm importdisk 9000 debian-13-pve-sunoaki+YYYYMMDD.qcow2 local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --scsi2 local-lvm:cloudinit
qm set 9000 --ide2 none --boot order=scsi0 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1 --ostype l26
qm template 9000
```

这 8 个镜像的 `qm create` 参数相同，无需按发行版区分，也无需按发行版选固件：全部 8 个条目都同时带有 ESP 与 BIOS 引导路径，SeaBIOS（PVE 默认）和 OVMF 都能启动，两条路径都已在本地各测一遍，全部到达 login 提示。PVE 上保持默认的 SeaBIOS，或在 VM 的「硬件 → BIOS」里选 OVMF，两者都可以。

CentOS 7 是唯一需要额外处理的条目：上游的 GenericCloud 镜像从来没有 UEFI 变体，它只有一个 MBR 分区、完全没有 ESP，所以这个 ESP 是流水线自己加的（`config/images.yaml` 的 `efi_esp: true`）——构建时在磁盘尾部追加一个 100MiB 的 FAT32 分区，由 `rhel.sh` 从镜像自身的仓库装 `grub2-efi-x64`、`grub2-efi-x64-modules`、`shim-x64`（连带 `mokutil`、`efivar-libs`），并把 `/boot/efi` 写进 `/etc/fstab`。原有的 MBR 引导路径完全不动，所以两条固件路径都可用。

CentOS 7 需要**两份** grub.cfg，这与 Rocky 不同：Rocky 的 `/boot/grub2/grub.cfg` 里没有内核命令名（内容是 `blscfg` 调用，由它在运行时按固件选），所以 Rocky 的 ESP 配置只需指向 root 分区上的那份；CentOS 7 的 grub.cfg 里写着真正的内核命令行，BIOS 用的是 `linux16`/`initrd16`、UEFI 用的是 `linuxefi`/`initrdefi`，两个名字在对方的 GRUB 里都不存在。因此 BIOS 那份写成 `linux16`，ESP 上那份写成 `linuxefi`，各自钉死。

ESP 里只有引导器，内核与 initramfs 放在 root 分区或独立的 `/boot` 分区（Rocky 是 XBOOTLDR 类型的 `p3`）上，所以给模板装新内核不占 ESP 空间。实测 Rocky 10 的 ESP 占用 13.8MiB（容量 199.7MiB），其 `p3` 的 `/boot` 占用 372MiB（容量 936MiB）；CentOS 7 新加的 ESP 容量 100MiB。

之后从模板克隆 VM，在 VM 的 Cloud-init 面板设置 user=`root` 和密码即可通过 SSH 密码登录。

## 支持矩阵

构建列表在 `config/images.yaml` 中（workflow 读取该文件生成矩阵），目前包含 8 个条目：

| 发行版  | 版本                             | family   | 官方源                  | 包源格式                  |
| ------- | -------------------------------- | -------- | ----------------------- | ------------------------- |
| Debian  | 13 (trixie) / 12 (bookworm)      | `debian` | cloud.debian.org        | DEB822 (`debian.sources`) |
| Ubuntu  | 26.04 (resolute) / 24.04 (noble) | `debian` | cloud-images.ubuntu.com | DEB822 (`ubuntu.sources`) |
| Ubuntu  | 22.04 (jammy)                    | `debian` | cloud-images.ubuntu.com | legacy (`sources.list`)   |
| Rocky   | 9 (blue-onyx) / 10 (red-quartz)  | `rhel`   | dl.rockylinux.org       | rpm (`.repo`)             |
| CentOS  | 7 (core，EOL，`frozen: true`)    | `rhel`   | cloud.centos.org        | rpm (`.repo`，改用 vault) |

`family` 字段选择 `scripts/family/<family>.sh`，它提供各家族不同的钩子；`sources_format` 只对 Debian 系起作用（`deb822` / `legacy`），RHEL 系填 `rpm`，但 `rhel.sh` 不读这个字段，它自己改写 `/etc/yum.repos.d/*.repo`。

分区布局由脚本按内容探测（挂载候选分区后找 `/etc`），不依赖分区编号。实测各条目的布局如下：

| 条目 | 分区表 | root | 独立 `/boot` | ESP | 启动测试使用的固件 |
| --- | --- | --- | --- | --- | --- |
| Debian 12 / 13 | GPT | p1 | 无 | p15 | efi |
| Ubuntu 22.04 | GPT | p1 | 无 | p15 | efi |
| Ubuntu 24.04 | GPT | p1 | p16 | p15 | efi |
| Ubuntu 26.04 | GPT | p1 | p13 | p15 | efi |
| Rocky 9 / 10 | GPT | p4 | p3 (XBOOTLDR) | p2 | efi |
| CentOS 7 | MBR | p1 | 无 | p2 (构建时新加) | efi |

Rocky 的 root 在 p4 而非 p1，这是本表逐条实测的原因：p1 是 `p.legacy`（BIOS boot 分区，类型 `21686148-…`），p2 是 ESP，p3 是 XBOOTLDR。root 分区由内容判定（找 `/etc`），因此这个编号差异不需要脚本知道。

上表每个条目都同时有 BIOS 引导路径与 ESP，这是两条固件路径都能启动的原因。BIOS 引导路径是 Debian 与 Ubuntu 的 BIOS boot 分区 p14（Rocky 的 p1）加上 CentOS 7 的 MBR；两张表里都没有列前者，因为它不含文件系统，只承载 GRUB 的 core 镜像。

`启动测试使用的固件` 取自 CI 日志里的 `Firmware for boot test:` 一行。固件由 ESP 决定：`scripts/partition-layout.sh` 的 `layout_firmware()` 依分区类型判定（GPT 上是 `c12a7328-…` 这个 GUID，MBR 上是 `0xef` 这个类型字节），而 CentOS 7 的 ESP 是构建时加的，所以 `scripts/customize-image.sh` 在算出要建 ESP 时就记成 `efi`，不再看初始分区表。一次构建只能测一种固件，因此 CentOS 7 的 UEFI 路径由 CI 启动测试覆盖、BIOS 路径由 SeaBIOS 本地实测覆盖。RHEL 系默认开启启动测试（`vars.BOOT_TEST`），Debian 系默认关闭，因此上表 Debian/Ubuntu 条目记录的是固件判定结果，不是实际跑过的启动记录。

新增发行版只需在 `config/images.yaml` 里加一条记录（并在 PVE 侧 `update-cloud-templates.sh` 里加一个模板 VMID），产物会自动变为 `<distro>-<major>-pve-sunoaki+YYYYMMDD.qcow2` 并合并进同一个 Release。若上游镜像的根文件系统是 XFS，`family: rhel` 会走挂载后 `xfs_growfs` 的扩容路径（runner 需装 `xfsprogs`）；ext4 走挂载前 `resize2fs`。两者的顺序不可互换。
