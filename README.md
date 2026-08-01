# cloud-image

基于 GitHub Actions 自动构建适用于 **Proxmox VE (PVE)** 的 Debian / Ubuntu Cloud Image（Debian 12、13；Ubuntu 22.04、24.04、26.04），并把所有版本合并为一个**按日期命名**的 GitHub Release，方便 PVE 侧自动下载。构建配置已矩阵化，新增发行版只需在矩阵里加一行配置。

## 构建流程

1. 从官方源下载云镜像（Debian 用 SHA512、Ubuntu 用 SHA256 校验）
2. `qemu-nbd` 挂载 → **chroot 原生 apt 定制**（不使用 TCG/虚拟机模拟，构建速度快）
3. 压缩为 qcow2 并上传 artifact
4. `release` job 合并所有版本的镜像，按日期发布单个 Release

每次构建产生：

- `debian-12-pve-sunoaki+YYYYMMDD.qcow2`
- `debian-13-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-22.04-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-24.04-pve-sunoaki+YYYYMMDD.qcow2`
- `ubuntu-26.04-pve-sunoaki+YYYYMMDD.qcow2`

Release tag 为 `YYYYMMDD`；同一天重复构建会先删除当天的旧 Release 再发布新版本。

## 镜像定制内容

- 预装：`qemu-guest-agent spice-vdagent aria2 net-tools iputils-ping iputils-arping iputils-tracepath mtr-tiny dnsutils sudo bash-completion unzip wget curl nano most screen less vim bzip2 lldpd htop zstd tmux`
- 时区 `Asia/Hong_Kong`；systemd-timesyncd 使用 `NTP=time.apple.com time.windows.com`
- GRUB 禁用 OS-Prober（避免 loopback 探测导致无法启动）；启用 `serial-getty@ttyS1` 串口登录
- 关闭 cloud-init 启动时重新生成 apt 源；apt 源去掉 `deb-src`（DEB822 与旧式 `sources.list` 两种格式均处理）
- **root + SSH 密码登录**：cloud-init `disable_root: false`、`ssh_pwauth: true`，sshd `PermitRootLogin yes`。配合 PVE cloud-init 默认配置（user=root + 设置密码）即可直接密码登录
- root 自定义 PS1 提示符（`\[\033[01;35m\]\$` 单引号写法，root 显示 `#`）
- **BBR + TCP 调优**：`fq` qdisc、`tcp_slow_start_after_idle=0`、`tcp_fastopen=3`
- 清理日志 / apt 缓存 / `/tmp`，`/etc/machine-id` 置空

## 触发构建

在 GitHub Actions 页面手动运行（`workflow_dispatch`），或：

```bash
gh workflow run build-cloud-image.yml
```

## PVE 使用

下载最新 Release（PVE 节点上需先配置 `gh` 或直接用 GitHub API）：

```bash
TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
gh release download "$TAG" --pattern 'debian-13-*.qcow2'   # 或 ubuntu-24.04-*.qcow2
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

之后从模板克隆 VM，在 VM 的 Cloud-init 面板设置 user=`root` 和密码即可通过 SSH 密码登录。

## 支持矩阵

构建列表在 `.github/workflows/build-cloud-image.yml` 的 `strategy.matrix.include` 中，目前包含：

| 发行版 | 版本 | 官方源 | apt 源格式 |
|---|---|---|---|
| Debian | 13 (trixie) / 12 (bookworm) | cloud.debian.org | DEB822 (`debian.sources`) |
| Ubuntu | 26.04 (resolute) / 24.04 (noble) | cloud-images.ubuntu.com | DEB822 (`ubuntu.sources`) |
| Ubuntu | 22.04 (jammy) | cloud-images.ubuntu.com | legacy (`sources.list`) |

新增发行版只需加一行 `include`，产物会自动变为 `<distro>-<major>-pve-sunoaki+YYYYMMDD.qcow2` 并合并进同一个 Release。注意 `sources_format` 字段：22.04 用 `legacy`，其余用 `deb822`；root 分区由脚本自动探测（Ubuntu ≥ 24.04 的 root 在 p2，p1 为 EFI 分区）。

## 目录结构

```
.github/workflows/build-cloud-image.yml   # 构建工作流（矩阵 + chroot 定制 + 合并 Release）
```
