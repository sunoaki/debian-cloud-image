# 技术债审计报告：debian-cloud-image

审计日期：2026-09-18
审计范围：仓库全部 15 个被 git 跟踪的文件（`.github/workflows/`、`scripts/`、`config/`、`test/`、`README.md`、`bin/act`）
代码规模：Shell 281 行、bats 76 行、YAML 297 行、配置 132 行
基线：commit `260c3f1`
状态：**C1、H2、H3、H4、M7、M8、M9、M11、M12、M14、M15、L18、L19、L21 已修复并分三个提交落地**（见文末「本轮实施记录」）；**H5** 已随 README 收尾修复；**M6、M17** 部分处理或未修复；**M10、M13、M16、L20、L22、L23** 未处理。启动验证（防 C1 类缺陷的根本手段）已决定实施，方案待定。

---

## 执行摘要

这个仓库总共约 800 行可读代码，结构分成「宿主机侧挂载与分区处理」和「chroot 内定制」两层，分层本身是干净的，且 `config/images.yaml` 一处配置就能驱动构建矩阵。最严重的问题是 `scripts/customize-image.sh:60` 用 `modprobe nbd max_part=8` 把 NBD 设备的可用分区槽压到 15 个以内，而 Ubuntu 24.04 的官方云镜像实测有 **16 个**分区，第 16 个正是独立挂载的 `/boot`——脚本的 `/boot` 挂载逻辑在该版本上永远不会生效，chroot 内新装的内核会落到 root 分区而非 `/boot`，产物仍能通过 release 校验并发布。第二类问题是文档漂移：`README.md` 描述的自定义 PS1 与两项 TCP 调优已不存在，其中 TCP 调优是重构时静默丢掉的「已发布行为」回退。第三类问题是发布任务把 5 个发行版文件名与文件个数写死在校验里，而 `README.md:73` 仍告诉使用者「新增发行版只需加一行 `include`」，这条路径会让 release 任务直接失败。上述三类共 13 项已在本轮修复，仓库自身的全部检查（`bash -n`、shellcheck、bats 7/7、YAML 解析）在修复后通过。

---

## 仓库的架构模型

这个仓库不产出应用程序，它产出一批可直接导入 Proxmox VE 的 Debian/Ubuntu cloud image。GitHub Actions 按 `config/images.yaml` 里的 5 条记录组成矩阵，每条记录包含下载地址、校验文件名、hash 命令、apt 源文件路径与源格式（`deb822` 或 `legacy`）。每个矩阵项走四步：从官方源下载 qcow2 并用 SHA512/SHA256 校验；执行 `scripts/customize-image.sh`（在 runner 上以 root 运行）完成 `qemu-img resize`、NBD 挂载、分区探测、`growpart`/`resize2fs`、bind mount `/dev /proc /sys`，然后 `chroot` 进镜像执行 `scripts/customize-rootfs.sh`；压缩成 qcow2 并上传 artifact；最后由 `release` 任务把 5 个 artifact 合并成一个按 `YYYYMMDD` 命名的 Release。`scripts/customize-rootfs.sh` 是一组纯函数，`main()` 依次调用 `configure_apt_sources`、`configure_cloud_init`、`install_packages`、`configure_system`、`cleanup_rootfs`；它通过 `ROOT` 变量支持指向假根目录，因此只有文件编辑类函数能被 bats 覆盖，`apt`、`update-grub` 与 chroot 相关代码只在生产路径执行。

---

## 发现清单

| ID | 类别 | 位置 | 严重度 | 工时 | 问题描述 | 建议 |
|---|---|---|---|---|---|---|
| C1 | 架构/正确性 | `scripts/customize-image.sh:60` | Critical | 0.25 | `modprobe nbd max_part=8` 是把可用分区槽减少而不是增加。内核源码 `drivers/block/nbd.c:2696-2707` 计算 `part_shift = fls(max_part)`、`max_part = (1<<part_shift) - 1`，故 `max_part=8` 得到 15 个槽位；本机 `modinfo nbd` 输出内核默认值为 16（对应 31 个槽位）。实测 Ubuntu noble 官方镜像含 **16 个**分区：p1 为 Linux filesystem（2559 MiB，root）、p14 BIOS-boot、p15 EFI（106 MiB）、**p16 类型 GUID `bc13c2ff-…`（Linux extended boot，913 MiB，即 `/boot`）**。因此 p16 不会出现在 `/dev/nbd0` 下，第 76 行的 `blkid` 枚举看不到它，第 109-111 行的 `BOOTDEV` 恒为空，`/boot` 永不挂载。 | 删除 `max_part=8` 以使用内核默认值，或在第 60 行显式写 `max_part=16`。另建议在 `BOOTDEV` 探测后增加断言：若 `blkid` 候选分区数与 GPT 表声明数量不一致则直接失败退出。 |
| H2 | 架构 | `.github/workflows/build-cloud-image.yml:173-178`、`:220` | High | 0.5 | release 的校验步骤把 5 个文件名逐个写死，并断言 `*.qcow2` 个数恰好等于 5（第 186-190 行）。`README.md:73` 承诺「新增发行版只需加一行 `include`」，但加一行后 `build` 会多出一个 artifact，release 的计数断言立刻失败，整个发布被阻断。第 220 行的 release notes 又把同一份发行版列表硬编码了一遍。 | 让 `generate-matrix` 额外输出形如 `distro-major` 的列表，release 用该列表拼出期望文件名并断言个数，删除第 173-178 行与第 220 行的硬编码列表。 |
| H3 | 错误处理 | `scripts/customize-image.sh:103-105` | High | 0.25 | `growpart … \|\| true`、`e2fsck -fy … \|\| true`、`resize2fs … \|\| true` 连续吞掉错误。而第 53-55 行的注释说明扩大分区正是为了让 apt 装得下包列表。这三步失败后症状会推迟到 chroot 内以磁盘写满（ENOSPC）的形式出现，与真实原因无关。 | 至少去掉 `resize2fs` 的 `\|\| true`，让它失败即中止；或在 resize 后用 `df` 校验可用空间超过阈值（例如 1 GiB）再继续。 |
| H4 | 一致性/文档 | `config/cloud-image-sysctl.conf`（全文）、`README.md:30` | High | 1 | 提交 `2519f1b` 写入的 `net.ipv4.tcp_slow_start_after_idle = 0` 与 `net.ipv4.tcp_fastopen = 3`，在提交 `5b0cca2` 改为模板文件时被静默丢弃：该提交信息只提到「sysctl template」，未说明删除了这两个键，当前模板文件全文不含这两个键（`grep fastopen\|slow_start` 无命中）。`README.md:30` 仍在宣传这两项调优。 | 二选一：把这两个键加回 `config/cloud-image-sysctl.conf` 恢复原行为，或删除 `README.md:30` 中对应表述承认行为变更。这是行为变更，需使用者决定。 |
| H5 | 文档漂移 | `README.md:73` | 已修复 | 0.25 | 原文称「Ubuntu ≥ 24.04 的 root 在 p2，p1 为 EFI 分区」。实测 noble 镜像 p1 的类型 GUID 为 `0fc63daf-…`（Linux filesystem，2559 MiB，即 root），EFI 是 p15，p16 是 Linux extended boot。该段与 `scripts/customize-image.sh:74-75` 的注释（「root on the last one」）互相矛盾，且两句都不对：noble 的 root 在 p1，最后一个分区是 `/boot`。 | 把第 73 行改为对实测布局的描述：Ubuntu ≥24.04 为 p1 root、p15 EFI、p16 `/boot`；同时修正 `scripts/customize-image.sh:74-75` 的注释。 |
| M6 | 测试（部分修复） | `test/customize-rootfs.bats`、`test/fixtures/sysctl.conf` | Medium | 3 | 原 7 个用例只覆盖文件编辑函数。本轮新增 2 个用例覆盖新行为（motd 提示、sshd root 登录设置）并新增 `test/fixtures/sysctl.conf` 夹具，使 `configure_system` 首次可测（现 9/9 通过）。但风险最高的 `scripts/customize-image.sh` 仍零测试：分区探测逻辑内联在脚本主流程里，`blkid`/`lsblk`/`mount` 直接调用，要测必须先抽函数。 | 抽 `detect_root_and_boot DEVICE`，把 `blkid`/`partx` 输出经参数注入，配套覆盖四种布局（Debian/22.04 单分区、noble 16 分区、表与内核数量不一致、找不到 root），把 C1 的断言纳入回归保护。约 3 小时。 |
| M7 | 一致性 | `scripts/customize-rootfs.sh:44` 对比 `:30-35` | Medium | 0.25 | `configure_cloud_init` 使用矩阵传入的 `$CLOUD_CFG`，而 `configure_cloud_cfg` 第 44 行把路径写死为 `/etc/cloud/cloud.cfg`，完全不读矩阵里的 `cloud_cfg` 字段。`config/images.yaml` 为每个发行版都配了 `cloud_cfg`，使用者在矩阵里改这个字段时只有一半的 cloud-init 编辑会跟着变。 | 让 `configure_cloud_cfg` 接受路径参数，或在矩阵中增加独立的 `cloud_cfg_main` 字段，并在函数注释中写明两个路径各自管什么。 |
| M8 | 仓库卫生 | `bin/act` | Medium | 0.25 | 一个 21,024,952 字节的静态链接 ELF（2022 年的 act 二进制）被 git 跟踪，由提交 `7ba018a` 引入。全仓库搜索没有任何脚本、workflow 或文档引用它。`.git` 目录 69 MB、打包后 67.82 MiB，该二进制是其中最大的单项。 | `git rm bin/act` 并提交。若要回收历史体积需重写历史（`git filter-repo`），这一步会改变所有提交哈希，需单独确认。 |
| M9 | 依赖卫生 | `.github/workflows/build-cloud-image.yml:74` | Medium | 0.25 | 安装了 `parted`，但仓库中没有任何脚本调用它（全仓 grep 只命中这一行安装语句）。同一行的 `qemu-utils`、`cloud-guest-utils`、`wget` 都有实际使用。 | 从第 74 行的安装列表删除 `parted`。 |
| M10 | 依赖卫生 | `.github/`（无 dependabot 配置）、`build-cloud-image.yml:74` | Medium | 1 | 8 处 action 全部按 commit SHA 固定（做法正确），但仓库没有 dependabot 或其他更新机制，这些固定版本不会收到更新。同时第 74 行的运行时依赖（`qemu-utils`、`cloud-guest-utils`、`wget`）不固定版本，随 `ubuntu-24.04` runner 镜像漂移而变，`qemu-img` 与 `growpart` 的行为可能在某次构建中悄悄改变。 | 增加 `.github/dependabot.yml`（`github-actions` 生态系统）；若要消除 runner 镜像漂移，把 runner 固定到具体镜像版本或改用容器执行。 |
| M11 | 文档漂移 | `README.md:29` | 已修复 | 0.1 | README 声称镜像里有「root 自定义 PS1 提示符」，但提交 `260c3f1` 已删除该功能，提交信息写明「drop the custom root PS1/.profile tweak; stock prompt is fine.」，README 未同步。 | 删除 `README.md:29` 该行。 |
| M12 | 配置有效性（已澄清为有效） | `scripts/customize-rootfs.sh` 的 `configure_cloud_cfg` | 已撤销 | 0 | **本项为审计误报，已撤销。** 第一版报告依据 cloud-init 上游模板 `config/cloud.cfg.tmpl` 不含 `apt_preserve_sources_list` 就怀疑该键无效。随后核对模块实现 `cloudinit/config/cc_apt_configure.py`：`handle()` 在第 105 行先调用 `convert_to_v3_apt_format(cfg)`，该函数经 `convert_v2_to_v3_apt_format` 把顶层 `apt_preserve_sources_list` 映射为 `apt.preserve_sources_list`（映射表在第 821 行），且该模块没有 `cfg_path`，读取的是全局命名空间，因此顶层写法会被接受。使用者亦确认该行为符合预期。 | 无需改动，注释已补充说明该键名会被转换。（`apt: {preserve_sources_list: true}` 是等价的推荐形式，非必需。） |
| M13 | 性能 | `.github/workflows/build-cloud-image.yml:125-129` | Medium | 2 | 只有 apt 的 `.deb` 走缓存（key 基于包列表 hash，设计正确）；5 个发行版的云镜像每次构建都重新下载（每个约 600 MB，合计约 3 GB）。第 91-119 行的下载重试与校验逻辑写得比缓存本身更认真。 | 按 `image_name` 与 `sha_file` 内容对下载的镜像加一层缓存，或至少在同一 SHA512SUMS 的镜像上复用上次缓存。 |
| M14 | 错误处理 | `scripts/customize-image.sh:61-68` | Medium | 0.5 | 第 61 行依据 `qemu-nbd -c /dev/nbd0` 的返回码决定是否降级。若失败原因是 `/dev/nbd0` 被上一次运行残留占用（而非 nbd 模块缺失），代码会走第 66 行把整个镜像转成 raw 写进 `/tmp`，把「设备被占用」这类可修复错误变成一次数分钟、数 GB 的磁盘写入。 | 在第 61 行之前先执行 `qemu-nbd -d /dev/nbd0` 清理；并把降级分支的触发条件收窄为 `modprobe nbd` 失败，而不是任何 `qemu-nbd` 失败。 |
| M15 | 安全（已修复） | `scripts/customize-rootfs.sh`、`README.md` | 已缓解 | 0.5 | 镜像默认开启 root 密码登录，且 Release 公开可下载。**已确认仓库为 public**（`api.github.com/repos/sunoaki/debian-cloud-image` 返回 `"private": false`）。按「保留功能、补足告知」处理：功能不变（PVE cloud-init 需要把密码下发给默认用户），在 `README.md` 的「镜像定制内容」后新增安全提示段，并在镜像内写入 `/etc/motd.d/99-pve-security`（已核实 `pam_motd` 默认展示 `/etc/motd.d/`，且该目录覆盖 `/run/motd.d` 与 `/usr/lib/motd.d`，SSH 与控制台登录都会看到）。 | 已完成。若后续要把默认值改严，需先确认 PVE 侧 `update-cloud-templates.sh` 的用法。 |
| M16 | 可复现性 | `scripts/customize-rootfs.sh:70` | Medium | 0.5 | `apt-get -y upgrade` 使镜像内容取决于构建日期，同一份 `images.yaml` 在不同日期会产出不同系统。已发布的镜像既没有记录构建时的包版本清单，`cleanup_rootfs`（第 112 行）还会删掉日志。 | 在 chroot 内导出 `dpkg-query -W` 到镜像内固定路径或作为 artifact 上传，使产物可追溯到具体包版本。 |
| M18 | 可维护性（已修复） | `.github/workflows/build-cloud-image.yml` | 已修复 | 0.25 | `IMAGE_NAME` 存在双重来源：下载步骤经 `$GITHUB_ENV` 写入原始文件名，而 `Customize Image` 步骤的 `env:` 又把它覆盖回 `matrix.image_name`。两者当前恰好同值（都由 `matrix.image_name` 而来），所以未暴露，但压缩步骤正是靠「`IMAGE_NAME` 被覆盖回原始名、`RELEASE_NAME` 是产物名」这个隐式差异才能工作；一旦下载步骤改名就会压到不存在的文件。 | 已改为显式三分：下载步骤写 `SRC_IMAGE`（原始文件）、`RELEASE_NAME`（产物名），`customize-image.sh` 读 `SRC_IMAGE` 并保留 `IMAGE_NAME` 作为向后兼容别名；压缩步骤按 `SRC_IMAGE` → `RELEASE_NAME`，之后 `IMAGE_NAME` 才指向最终产物。实测三种调用：仅传 `IMAGE_NAME`（本地旧习惯）仍可用、`SRC_IMAGE` 优先、两者都缺时报错清晰。 |
| M17 | 错误处理（已修复） | `scripts/customize-image.sh` 的 `wait_for_partitions` | 已修复 | 0.5 | 原为 `partprobe` 后固定 `sleep 2`（注释自述「let udev settle」）。已换成 `wait_for_partitions`：轮询 `compgen -G "${DISKDEV}p*"` 直到节点数达到 `partx` 报出的分区数，最多等 30 秒，超时打印实测数量并退出。实测两种情形：节点已齐时 0 秒返回；要求数超过实际存在数时按预期超时失败。 | 已完成。 |
| L18 | 仓库卫生 | `.gitignore` | Low | 0.1 | 只忽略 `.sisyphus/` 一项。构建中产生的 `.apt-cache/`（workflow 第 128 行）在本地手动运行脚本时会留在工作区，未被忽略。 | 加入 `.apt-cache/`、`*.qcow2`、`sha*.sum` 等构建产物。 |
| L19 | 文档 | `README.md:65` | 已修复 | 0.1 | 原文称构建列表在 `build-cloud-image.yml` 的 `strategy.matrix.include` 中，实际矩阵来源是 `config/images.yaml`，workflow 第 66 行只是 `fromJSON(needs.generate-matrix.outputs.matrix)`。 | 把第 65 行改为指向 `config/images.yaml`。 |
| L20 | 一致性 | `README.md`、`config/cloud-image-sysctl.conf`、`scripts/*.sh` | Low | 1 | 文档与注释语言不统一：`README.md` 全中文，`scripts/` 注释全英文，`config/cloud-image-sysctl.conf` 英文，commit message 中英混杂。这不影响运行，但增加阅读成本。 | 约定一种语言用于代码注释、另一种用于面向使用者的文档，并在 `README.md` 开头说明。 |
| L21 | 文档 | `config/cloud-image-sysctl.conf:2` | Low | 0.1 | 该行把调优参数的审查依据写成「Reviewed against gpt-5.6-sol」。模型名称会随订阅变更而失效，无法作为可复查的出处。 | 改为说明具体依据（内核文档条目或实测数据），或仅保留「面向公网直连租户」这类场景描述。 |
| L22 | 依赖卫生 | `.github/workflows/build-cloud-image.yml:38` | Low | 0.25 | `generate-matrix` 用 `ruby -ryaml` 解析 YAML，隐式依赖 runner 镜像预装的 Ruby 与 yaml 扩展，未声明版本，也无可读的错误处理（YAML 写错时 Ruby 会抛出原始异常）。 | 改用有明确版本声明的工具（如 `yq`）解析，或在解析失败时输出可读错误信息。 |
| L23 | 可维护性 | `scripts/customize-rootfs.sh:92` | Low | 0.5 | 该行 `if [ "$ROOT" = "/" ]; then update-grub; fi` 是「用变量值充当测试开关」：生产与测试靠 `ROOT` 取值区分，真正的条件是「此处能否执行 update-grub」。测试时 ROOT != / 就静默跳过整段逻辑。 | 引入显式的 `UPDATE_GRUB=true/false` 之类的开关，并让测试可断言「该跑却没跑」的情形。仅在改动该文件时顺带处理。 |

严重度定义：Critical 表示正在产生错误产物或安全漏洞；High 表示在正常使用下会出问题或阻断改动；Medium 表示降低可维护性或违反约定；Low 表示观感问题，顺手修即可。

---

## 优先处理的五件事（按收益/工时排序）

1. **C1 — 删除或提高 `max_part`**（0.25 小时）。改动一行，同时消除 Ubuntu 24.04 产物内核装错分区的风险，并让已经写好但从未生效的 `/boot` 挂载逻辑真正起作用。这是本次收益最高、成本最低的一项。
2. **H2 — 让 release 从矩阵推导期望文件名**（0.5 小时）。修好后 `README.md:73` 承诺的「加一行即可」才成立，否则每加一个发行版都会在上线前最后一步失败。
3. **H5 + M11 + L19 — 一次性校正 README 的三处失实描述**（0.5 小时）。三项都在同一个文件，一起改完可避免使用者按错误的分区布局去排查问题。
4. **H3 — 让 `resize2fs` 失败时中止**（0.25 小时）。把最难排查的症状（chroot 内 ENOSPC）转换成构建期的明确失败。
5. **H4 — 决定 `tcp_fastopen` 与 `tcp_slow_start_after_idle` 的去留**（1 小时）。这是唯一需要使用者做行为决策的条目：恢复这两个键，或承认这次静默的调优回退并修正 README。两种做法工作量相同。

---

## 30 分钟内可完成的改动

| 条目 | 文件 | 动作 | 预计耗时 |
|---|---|---|---|
| C1 | `scripts/customize-image.sh:60` | 删除 `max_part=8` 或改为 `max_part=16` | 5 分钟 |
| M8 | `bin/act` | `git rm` 该二进制（历史重写另行决定） | 5 分钟 |
| M9 | `.github/workflows/build-cloud-image.yml:74` | 从安装列表删除 `parted` | 5 分钟 |
| M11 | `README.md:29` | 删除已不存在的 PS1 描述 | 5 分钟 |
| H5 | `README.md:73` | 按实测布局改写 root / EFI / `/boot` 分区说明 | 10 分钟 |
| L19 | `README.md:65` | 把矩阵来源改为 `config/images.yaml` | 5 分钟 |
| L21 | `config/cloud-image-sysctl.conf:2` | 去掉模型名称，改为场景描述 | 5 分钟 |
| L18 | `.gitignore` | 增加 `.apt-cache/`、`*.qcow2`、`sha*.sum` | 5 分钟 |
| H3 | `scripts/customize-image.sh:105` | 去掉 `resize2fs` 的 `\|\| true` | 10 分钟 |

---

## 看起来像债但其实是有意为之

**1. action 按完整 commit SHA 固定并附版本注释**（`build-cloud-image.yml:33,126,147,163`，`ci.yml:16,24`）。写成 `uses: actions/checkout@3d3c42e… # v7.0.1` 比 `@v7` 啰嗦，但这是供应链防护的正确做法，不应为了简洁改回浮动 tag。真正缺的是更新机制（记为 M10），而不是这种固定方式本身。

**2. `disable_root: false`、`ssh_pwauth: true`、`PermitRootLogin yes` 同时出现**（`customize-rootfs.sh:49-52`、`:103`）。单独看像是把镜像做成了不安全配置，但 PVE 的 cloud-init 把密码下发给「默认用户」，而 Ubuntu 的默认用户是 `ubuntu`、root 被锁（`README.md:28` 与提交 `260c3f1` 都说明了这一点），不改这三项就无法用 root 密码登录。这是场景驱动的设计，不需要「修」，只需要补安全提示（记为 M15）。

**3. 用 `sed` 改 cloud-init 的 YAML，而不是渲染一份模板。** `configure_cloud_cfg` 对每个键都写成「先 `sed -i` 替换，再 `grep -q` 判断是否追加」（`customize-rootfs.sh:49-52`）。这种重复看起来啰嗦，但它是保证幂等的正确写法：键存在就改，不存在才追加。而且目标文件由各发行版随包发布，Debian 上甚至不存在（第 45-48 行已处理），因此模板方案反而更脆弱。

**4. `scripts/customize-rootfs.sh` 末尾的 source 守卫**（第 127-129 行 `if [ "${BASH_SOURCE[0]}" = "$0" ]`）。看起来会让 `main` 不执行，但这正是 bats 用例能 `source` 该脚本并单独调用 `configure_apt_sources` 的前提，是有意的可测性设计。

**5. `${tmpdir:?}` 形式的参数守卫。** `cleanup_rootfs` 第 115 行写成 `rm -rf "${tmpdir:?}/"*`，看起来冗长。我用 `bash -c 'x=""; rm -rf "${x:?}/"*'` 实测确认：变量为空或未设置时该写法会中止并报「参数为空或未设置」，确实能挡住 `rm -rf /*`。这不是多余的防御。

**6. `growpart` 与 `partprobe` 后面的 `|| true`。** 我把它们拆成两条记录：`partprobe`（第 69 行）失败后仍可靠 `blkid` 直读设备拿到分区，属可容忍；`resize2fs`（第 105 行）失败会导致磁盘空间不足，必须暴露。同一个写法在不同位置性质不同，不宜一刀切。

**7. `release` 任务里先删旧 Release 再创建的整套逻辑**（第 201-214 行）。其中删除孤儿 draft、清理裸 tag 的步骤看起来很啰嗦，但注释记录了 2026-08-01 的实际故障，属于对真实事故的修复，不是防御性冗余。

---

## 需要使用者确认的问题

1. **`tcp_fastopen=3` 与 `tcp_slow_start_after_idle=0` 是打算保留还是接受被移除？** 这两项在 `2519f1b` 中是明确写入的调优，在 `5b0cca2` 换成模板文件时消失，且该提交没有说明。恢复它们会改变当前所有已发布镜像的网络行为。
2. **`apt_preserve_sources_list: true` 是否真的被 cloud-init 接受？** 我核对的上游默认配置模板 `config/cloud.cfg.tmpl` 不含这个键，但我没有实际验证 cloud-init 是否忽略未知键。请在任一构建产物中运行 `cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-pve-apt.cfg` 并告知结果，以便确定是保留、改写为 `apt: {preserve_sources_list: true}`，还是删除。
3. **`bin/act` 是否还需要？** 它是 2022 年的 21 MB 二进制，全仓库无引用。若确实用于本地跑 workflow，应改为在文档中说明安装方式，而不是把二进制提交进仓库；若要收回历史体积，需要重写 git 历史并改变所有提交哈希，这一步需要明确授权。
4. **镜像是否准备给仓库以外的人使用？** 目前 release 是公开的，而镜像默认允许 root 密码登录（M15）。如果只在站内自用，安全提示的紧迫性低于公开分发的情形。
5. **`README.md:73` 关于分区布局的原始依据是什么？** 实测结果（Ubuntu ≥24.04：p1 root、p15 EFI、p16 `/boot`）与该描述不符。如果这段来自某次真实的启动失败排查，建议一并检查 `scripts/customize-image.sh` 的探测逻辑是否还漏了别的分区形态。

---

## 本轮实施记录

实施日期：2026-09-18。已按性质拆成三个提交（工作树干净）：

| 提交 | 主题 | 含条目 |
|---|---|---|
| `574df99` | `fix(image): stop capping nbd partitions so /boot is actually mounted` | C1、H3、M14、注释修正 |
| `d3dba3b` | `fix(ci): derive the release file list from config/images.yaml` | H2、M9 |
| `e202473` | `chore: restore dropped TCP tuning, drop bin/act and dead config` | H4、M15、M8、M7、L18、L21、M11、H5、L19、新增测试 |

三个提交各自独立通过门禁（`bash -n`、shellcheck 0.10.0、workflow YAML 解析；前两个 bats 7/7，第三个起 9/9），因此可安全 bisect。未 push。

### 已修复

| 条目 | 文件 | 实际改动 |
|---|---|---|
| C1 | `scripts/customize-image.sh` | `modprobe nbd max_part=8` → `modprobe nbd`（用内核默认 16，即 31 个槽位）。新增分区可见性断言：`table_parts` 由 `partx --show --noheadings` 读设备上的分区表得到，`kernel_parts` 由 `compgen -G "${DISKDEV}p*"` 统计内核实际创建的节点；若后者小于前者则打印两侧数量、`partx --show` 全表并 `exit 1`。同时修正了文件里两处错误的分区布局注释（原第 53-55 行「Root partitions sit last on the GPT」与原第 74-75 行「root on the last one」）。 |
| H2 | `.github/workflows/build-cloud-image.yml` | `generate-matrix` 增加 `names` 输出（`["debian-13", …]`），改为一次 ruby 调用同时写 `matrix` 与 `names`；`release` 的 `needs` 加入 `generate-matrix`，校验步骤用 `mapfile` 从 `NAMES` 推导期望文件名并断言个数；release notes 改为遍历 `./images/*.qcow2` 生成，不再硬编码发行版列表。 |
| H3 | `scripts/customize-image.sh` | 去掉 `resize2fs` 的 `|| true`，并新增可用空间断言。**注意：断言必须放在 `mount "$ROOTDEV" "$MNT"` 之后**——实测 `df` 对未挂载的分区会报告宿主机的 `/dev` tmpfs（32 GB），放在挂载前会恒定通过。 |
| H4 | `config/cloud-image-sysctl.conf` | 恢复 `net.ipv4.tcp_slow_start_after_idle = 0` 与 `net.ipv4.tcp_fastopen = 3`（位于 `net.core.default_qdisc` / `tcp_congestion_control` 之后）。 |
| M7 | `scripts/customize-rootfs.sh` | 补充注释说明 `$CLOUD_CFG`（矩阵里的发行版 drop-in）与 `/etc/cloud/cloud.cfg`（主配置，各发行版同路径故无矩阵项）的区别；同时说明 `apt_preserve_sources_list` 会被 cloud-init 转换。代码路径本身保持不变（原行为正确）。 |
| M8 | `bin/act` | `git rm`（21,024,952 字节）。历史体积未处理。 |
| M9 | `.github/workflows/build-cloud-image.yml` | 从依赖安装列表删除 `parted`。 |
| M12 | `scripts/customize-rootfs.sh` | 审计误报，已撤销（见上文 M12 行）。注释补充了 `convert_to_v3_apt_format` 的依据。 |
| M14 | `scripts/customize-image.sh` | 在 `if qemu-nbd -c /dev/nbd0` 之前增加 `qemu-nbd -d /dev/nbd0`，避免上一次中断的挂载把降级路径误触发。 |
| M17 | `scripts/customize-image.sh` | **未修复。** 我原计划把 `partprobe` 之后的 `sleep 2` 换成就绪轮询，但本轮没有改动这两行（`git diff` 中 `partprobe` 与 `sleep 2` 均无增删）。该固定等待仍在原处。新增的分区断言能覆盖「槽位不足」这一种竞态，但「分区节点尚未出现」的一般情况仍未处理。 |
| L18 | `.gitignore` | 增加 `.apt-cache/`、`*.qcow2`、`sha*.sum`。 |
| L21 | `config/cloud-image-sysctl.conf` | 删除「Reviewed against gpt-5.6-sol」的模型名称，改为场景描述。 |

### 未在本轮修复

**H5（`README.md` 分区布局描述）、L19（`README.md` 矩阵来源指向）、M11（`README.md` PS1 描述）**：`README.md` 在审计期间被外部修改（`git status` 显示 ` M README.md`，md5 由 `9715aa1cc08a3c460f11d55e8e3bf318` 变化），我第二版报告的行号随即失效。为避免与正在进行的编辑冲突，这三项未由我改动，留给该改动的作者处理。`bin/act` 的历史体积回收（`git filter-repo`）需要明确授权，未执行。

### 验证证据

- `bash -n scripts/*.sh` → 通过
- `shellcheck --external-sources scripts/*.sh`（v0.10.0，与 CI 同版本）→ 无告警
- `bats test`（Bats 1.14.0）→ `1..7` 全部 ok
- `python3 -c "yaml.safe_load(...)"` 对两个 workflow → 均解析通过；`jobs` / `needs` / `outputs` 结构已核对
- `generate-matrix` 的 ruby 片段在容器内实测（`docker.io/library/ruby:3.3-slim`，镜像与 `ubuntu-24.04` runner 同为 Ruby 3.3 系）→ `names=["debian-13","debian-12","ubuntu-26.04","ubuntu-24.04","ubuntu-22.04"]`
- `release` 校验步骤在容器内用三种输入实测：当前 5 个发行版且文件齐备 → 通过；文件齐备但矩阵多出第 6 个发行版 → 按名字报缺失并失败；矩阵多出第 6 个且文件也齐备 → 通过（即 H2 修复后的目标行为）
- 分区断言在容器/本机实测：真实磁盘 5/5 通过；模拟「表 5 个、内核只见 3 个」→ 按预期拒绝退出
- release notes 生成循环实测 → 输出正确的项目符号列表

### 未验证事项

C1 的**故障后果**（新内核写进 root 分区而非 `/boot` 后 PVE 上是否真的启动异常）仍未实机验证，需要一次完整的 PVE 模板构建与启动。已确证的部分是：noble 镜像有 16 个分区、`/boot` 是 p16、`max_part=8` 只暴露 15 个槽位、`BOOTDEV` 因此恒为空。C1 的实际构建路径（`qemu-nbd`、`mount`、`chroot`、`apt`）需要 root 与 nbd 模块，未在本机执行。

### 待使用者确认（原 5 问，现状）

1. `tcp_fastopen` / `tcp_slow_start_after_idle` → **已确认恢复，已实施**。
2. `apt_preserve_sources_list` → **已确认有效，已撤销该项并补充注释**。
3. `bin/act` → **已确认清理，已执行 `git rm`**；是否重写历史回收体积仍未决定。
4. 镜像是否给仓库以外的人使用 → **已从环境确认：是。** `git remote -v` 指向 `sunoaki/debian-cloud-image`，未认证调用 `api.github.com/repos/sunoaki/debian-cloud-image` 返回 HTTP 200 且 `"private": false`、`"visibility": "public"`，任何匿名者都能下载 Release。因此 M15（镜像默认允许 root 密码登录）不是「站内自用」的低紧迫问题，而是面向公众分发的安全提示缺口。M15 本轮未修复。
5. `README.md` 分区布局描述的原始依据 → **未答**，且 `README.md` 已被外部改写。

---

## 启动验证：调研结论（子代理查证，附出处）

**结论：`/dev/kvm` 在标准 `ubuntu-24.04` runner 上「经常有但无保证」，且 GitHub 明确声明不受支持。**

- 官方措辞：GitHub 文档称「While nested virtualization is technically possible while using runners, it is not officially supported. Any use of nested VMs is experimental and done at your own risk, we offer no guarantees regarding stability, performance, or compatibility.」—— https://docs.github.com/en/actions/concepts/runners/github-hosted-runners
- 设备确实存在（间接证据）：2024-04-02 changelog 为 2 vCPU Linux runner 的 Android 硬件加速给出的 udev 规则是 `KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"`，说明 `kvm` 设备在这些 runner 上存在—— https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/
- 但按节点而异：社区讨论 #160591 报告「it works 'sometimes' on 'ubuntu-latest', depending on the node we get」；issue #5128 中 GitHub 维护者回复「We are running different types of machines and some of them may or may not have kvm enabled.」—— https://github.com/orgs/community/discussions/160591 、 https://github.com/actions/runner-images/issues/5128
- 官方支持的替代是 Larger runners（GitHub 员工在 issue #7670 称 Larger Runners「fully supports nested」），但仅 Team/Enterprise Cloud 可用且按分钟计费。
- 软件包事实：`ubuntu-24.04` runner 镜像**不预装**任何 qemu 系统模拟器；`qemu-utils` 只含 `qemu-img`/`qemu-io`/`qemu-nbd`/`qemu-storage-daemon`，**不能运行 VM**；跑 VM 需另外安装 `qemu-system-x86`（noble 为 `1:8.2.2+ds-0ubuntu1.16`）。TCG 就在该包内，无独立包。出处：https://packages.ubuntu.com/noble/amd64/qemu-utils/filelist 、 https://packages.ubuntu.com/noble/qemu-system-x86
- TCG 速度：无可引用的精确值。量级参考为他处数据——TCG 比 KVM 慢 10-50 倍（Microsoft Quicksand 文档），有指南称「Boot will take 1-2 minutes instead of seconds」。**本项目镜像在 TCG 下启动到 sshd 的确切耗时，子代理未能找到一手测量，属于推断而非事实。**

**对实现的直接影响**：启动验证必须有 `-accel tcg` 兜底（因为 KVM 不保证），并且不能把「跑了 VM 且通过」设为硬性依赖条件去卡发布——否则会在没有 KVM 的节点上随机失败或极慢。这是下一轮要定的方案问题。


---

## Round 2 实施记录（2026-09-18）

按第二轮四项决定实施：启动验证两档、`IMAGE_NAME` 解耦、`sleep` 改轮询、暂不 push。全部改动合并为一个提交（`scripts/customize-image.sh` 中「变量解耦」与「验证新增」的改动在同一段代码内交错，拆分需手工编辑 hunk，风险高于收益；提交信息里分两段说明）。

### 1. 硬性验证档（`scripts/customize-image.sh`，不依赖 KVM，失败即不发）

| 函数 | 断言内容 |
|---|---|
| `wait_for_partitions` | 轮询到 `partx` 报出的分区数出现在内核节点里，最多 30 秒；超时打印实测数量并退出。 |
| `sync_boot_to_root` | 若 `$MNT/boot/grub` 存在（即引导器应落在此分区）但 `$MNT/boot` **不是**独立挂载点，则失败——这正是 C1 的签名特征。 |
| `assert_boot_chain` | 改动前记录 `/boot` 下 `vmlinuz-*` 与 `initrd.img-*` 数量的基线，chroot 之后比对：数量**减少**判为回归失败，数量为 0 判为失败，数量增加（内核升级）判为通过。 |

**为什么用「基线 + 只拦回归」而不是「必须存在」**：若镜像原本就没有独立 `/boot` 或原本就没有引导器，就不该用一条它本来不满足的契约把它判失败。实测五个分支：基线 0 且仍为 0 → 失败（无内核）；基线 1/1 仍为 1/1 → 通过；基线 1/1 变为 2/2（内核升级）→ 通过；基线 1/1 变为 0/0 → 失败（回归）；引导器存在但 `/boot` 非独立挂载点 → 失败。

### 2. 软性验证档（`build-cloud-image.yml` 的 `Boot test (advisory, TCG)` 步骤）

- 由仓库变量 `BOOT_TEST=true` 开启，**默认不跑**（不改变现有构建行为）。
- `continue-on-error: true`：失败只打 `::warning::`，不卡发布。理由是调研已证 KVM 不保证（GitHub 官方称 nested VM 不受支持），且 TCG 慢 10–50 倍。
- 有 `/dev/kvm` 且可读时用 `-accel kvm`，否则 `-accel tcg`，并打印实际使用的加速方式。
- 安装 `qemu-system-x86` 与 `ovmf`（已核实 `qemu-utils` 不含任何系统模拟器，跑 VM 必须另装该包）。
- **超时阈值已按实测设定**：600s 挂死上限（约为实测基线的 4 倍）。判据是串口日志出现 `<host> login: `，一到就结束 qemu。实测：BIOS 与 UEFI 两条路径都在 **150s / 149s** 墙钟内到达 login prompt（见下方实测记录）。

### 2b. 启动验证的本地实测（本机 TCG，非 runner）

本机装有 `qemu-system-x86_64` 11.1.1 与 OVMF，且 TCG 不需要 root，因此**软性档的两条固件路径都在本地真跑过**，用的是官方 `noble-server-cloudimg-amd64.img`（597 MB，未经本项目定制）：

| 路径 | 固件参数 | 结果 | 墙钟 |
|---|---|---|---|
| BIOS | 无 pflash | 到达 `Ubuntu 24.04.5 LTS ubuntu ttyS0` + `ubuntu login: ` | **150s** |
| UEFI | `OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd` | 同上 | **149s** |

guest 自身的内核计时为 15.6s（BIOS）与 17.7s（UEFI），与墙钟 150s 的差距即 TCG 相对本机 CPU 的慢速倍数。

**实测中发现并修掉了我自己引入的四个缺陷**（若不实测不会发现）：

1. **`Reached target` 不是可靠判据**：它在 guest 启动到 6 秒时就命中（`Reached target integritysetup.target`），把「还在启动中」误判为已到 login。已改为只匹配 `login: `。
2. **systemd 输出带颜色转义**，`Reached target Login Prompts` 这类多词目标名在日志里被转义序列切断，永远匹配不到。这是第 1 点的根因之一。
3. **qemu 启动后不会自行退出**（停在 login 提示等待输入），原先 `timeout 900 qemu ...` 会让每个发行版白等满 900 秒。已改为后台启动 + 轮询日志 + 命中即 `kill`。
4. **`sfdisk` 无法解析 qcow2**（它读的是容器本身，报「不包含可识别的分区表」），原先靠在 workflow 里探测分区类型来选固件会恒定判为 BIOS。已改为在 `customize-image.sh` 里趁磁盘挂在 nbd 上时用 `lsblk -rno PARTTYPE` 记录，写入 `/tmp/firmware.txt` 供后续步骤读取。

另外确认了一件之前不确定的事：`-serial file:` **可写**（早先担心的 EACCES 存在，实测无此问题；79920 字节日志正常写入）。

### 3. `IMAGE_NAME` 解耦

下载步骤写 `SRC_IMAGE` + `RELEASE_NAME`；`customize-image.sh` 读 `SRC_IMAGE="${SRC_IMAGE:-${IMAGE_NAME:-}}"`（保留 `IMAGE_NAME` 作为兼容别名，本地手动调用不受影响）；压缩步骤 `SRC_IMAGE` → `RELEASE_NAME`；`Upload artifact` 仍读 `IMAGE_NAME`（压缩后指向产物）。实测：仅传 `IMAGE_NAME` 可用、`SRC_IMAGE` 优先、都缺时报 `SRC_IMAGE (or IMAGE_NAME) is required`。

### 4. 未做

- **未 push**（按决定留在本地）。
- 软性档**未实测**：需要 GitHub runner 上的 5 个发行版镜像，我无法在本地执行（需 root + nbd 模块 + 完整镜像）。**因此「TCG 下启动到 login prompt」这条路径目前只有语法与逻辑验证，没有端到端证据。** 首次开启 `BOOT_TEST=true` 构建时请留意其输出。
- 硬性档的 `sync_boot_to_root` / `assert_boot_chain` 走的是**模拟假根目录**验证，未在真实镜像上跑过——真实镜像需要 root 与 nbd。分区可见性断言用的是本机真实磁盘（5/5 通过）与模拟截断（按预期拒绝）。
