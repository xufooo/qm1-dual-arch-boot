# qm1-dual-arch-boot

为「64 位 CPU + 32 位 UEFI 固件」的 x86 设备构建**双架构 EFI 引导器**：
同一块启动介质既能引导 32 位系统，也能引导 64 位系统。

目标设备参考：ASUS QM1（Intel Atom Z3735F / Bay Trail，4 核，2 GB RAM，32 GB eMMC）。
方案对任何"CPU 支持 64 位、但固件只有 32 位 EFI"的 x86 设备通用。

[![build-bootloaders](https://github.com/xufooo/qm1-dual-arch-boot/actions/workflows/build-bootloaders.yml/badge.svg)](https://github.com/xufooo/qm1-dual-arch-boot/actions/workflows/build-bootloaders.yml)

---

## 背景：为什么需要 IA32 引导器

UEFI 固件加载 `.efi` 时按固件自身的位宽：

| 固件 | 能加载的格式 | 官方 `grubx64.efi`（PE32+） |
|---|---|---|
| 32 位 IA32 EFI | PE32（Intel 80386） | ❌ 直接拒绝 |
| 64 位 x86_64 UEFI | PE32+（x86-64），同时兼容 PE32 | ✅ |

很多 x86 平板/迷你机（出厂 Windows 8.1 / 32 位 Win10）就是「64 位 CPU + 32 位固件」。
直接拿 amd64 官方安装器往里装，通常会死在"装完了找不到引导器"这一步。

**解法**：用 GRUB 的 `i386-efi` 平台构建一个 32 位引导器（PE32），固件用 IA32 载入它，
它再加载 64 位内核（Linux 内核支持 EFI handover，由 32 位引导器切进 64 位模式）。

**关键事实**：64 位固件同样能加载 32 位 PE32 应用 ⇒ **32 位引导器对两种固件都安全**。
所以本仓库同时产出两个引导器，把"固件位宽未知"这个不确定性在介质层就吸收掉。

## 产物

| 文件 | 格式 | 部署路径 | 用途 |
|---|---|---|---|
| `grub2ia32.efi` | PE32 / Intel 80386 | `/EFI/BOOT/BOOTIA32.EFI` | 32 位固件的唯一入口（主用） |
| `grubx64.efi` | PE32+ / x86-64 | `/EFI/BOOT/BOOTX64.EFI` | 固件实为 64 位时的原生路径 |

两者共享同一份 `grub.cfg`，菜单里给出 64 位与 32 位两个启动项。

## 目录结构

```
scripts/
  build-bootloaders.sh      构建双引导器 + 形态/模块校验
  make-esp-image.sh         组装 FAT32 ESP 启动镜像（双引导器 + grub.cfg + 内核）
  grub.cfg.example          菜单模板（root=UUID 占位）
.github/workflows/
  build-bootloaders.yml     push/PR 自动构建并校验，产出 artifact
  build-esp-image.yml       手动触发，产出可写盘的 ESP 镜像
```

## 快速开始

### 本地构建（Linux）

```bash
# Debian/Ubuntu
sudo apt-get install -y grub2-common
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y grub-efi-ia32-bin:i386 grub-efi-amd64-bin:amd64

bash scripts/build-bootloaders.sh out
```

本机缺模块时，可让脚本自己去 Debian 拉**同版本**的包（避免 grub-mkimage 与 .mod 版本不一致）：

```bash
FETCH_DEBIAN=1 bash scripts/build-bootloaders.sh out
```

### 组装启动介质

```bash
bash scripts/make-esp-image.sh \
  --out out/qm1-dual-boot.img \
  --size-mib 512 \
  --bootloaders out \
  --root-uuid <64位根分区UUID> \
  --root32-uuid <32位根分区UUID>      # 可选；不给则不生成 32 位启动项

sudo dd if=out/qm1-dual-boot.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### CI

- **构建引导器**：`push` / `PR` 自动触发，产出 `qm1-bootloaders-<sha>` artifact。
- **组装 ESP 镜像**：Actions 页面手动触发 `build-esp-image`，填入根分区 UUID 即可。

CI 在 `debian:trixie-slim` 容器内运行，保证 `grub-mkimage` 与两套模块同版本。

## ESP 布局与 grub.cfg

```
QM1ESP/                        (FAT32, 卷标 QM1ESP)
├── EFI/BOOT/
│   ├── BOOTIA32.EFI           ← grub2ia32.efi
│   ├── BOOTX64.EFI            ← grubx64.efi
│   └── grub.cfg
├── vmlinuz      initrd.img        (64 位)
└── vmlinuz-32   initrd-32.img     (32 位)
```

```bash
set timeout=5
set default=0
search --label QM1ESP --set=root

menuentry "QM1 Debian 13 (64-bit amd64)" {
    linux  /vmlinuz    root=UUID=<64位根UUID> ro console=tty0 console=ttyS0,115200n8
    initrd /initrd.img
}
menuentry "QM1 Debian 13 (32-bit i386)" {
    linux  /vmlinuz-32 root=UUID=<32位根UUID> ro console=tty0 console=ttyS0,115200n8
    initrd /initrd-32.img
}
```

内核与 initrd 放在 ESP 上，好处是引导链路与根文件系统解耦，根分区坏了也能进救援。

## 关键坑

1. **`grub-efi-amd64-bin` 里没有 i386-efi 模块**；IA32 引导器必须从 i386 架构包 `grub-efi-ia32-bin` 取模块。
2. **`grub-mkimage` 与 `.mod` 必须同版本**，否则报模块不兼容。系统安装的 `grub2-common` + `grub-efi-*-bin` 天然同版本；跨源取包时要连 `grub2-common` 一起取。
3. **模块清单以本机模块目录为准**。GRUB 里**没有独立的 `linuxefi` 模块** —— EFI handover 支持在 `linux` 模块内（Debian trixie 的 i386-efi 模块集共 270 个，其中并无 `linuxefi.mod`）。网上教程常把 `linuxefi` 列进清单，照抄会直接构建失败。本仓库用 `ALL_MODULES=1` 可内嵌整个平台模块集（上游案例的做法）。
4. **`file` 的措辞随版本而变**：32 位产物可能显示 `Intel 80386` 也可能显示 `Intel i386`，断言要兼容两种。
5. **文件名必须是 `BOOTIA32.EFI`**，且位于 FAT32 的 `\EFI\BOOT\`。UEFI 可移动介质规范路径，写错固件就找不到。
6. **32 位 EFI 不能 chainload 64 位 EFI 程序**，但**能加载 64 位 Linux 内核**（走 EFI handover）。这是两件事，别混为一谈。
7. **Secure Boot 必须关闭**，否则自编译的 `.efi` 会被拒绝签名校验。
8. **不要在 chroot 里跑 `grub-install`** —— 它会写 64 位引导器，覆盖掉 IA32 跳板。
9. `linux`/`initrd` 的 `root=UUID=` 必须是真实 UUID，不能写猜测值。
10. **FAT32 介质要用 `mkfs.vfat` 建卷，别用 `mformat`** —— `mformat` 建的卷只有 8.3 短名支持：`grub.cfg` 会变成 `GRUB.CFG`，`vmlinuz-32` / `initrd-32.img` 这类名字会被直接截断，GRUB 在 ESP 上根本找不到文件。`mkfs.vfat -F 32` 建的是带长名表的 VFAT，`mcopy` 写入后文件名原样保留。本仓库 `make-esp-image.sh` 默认走这个后端，CI 里 `mdir -/` 的断言就是为了回归检查这一点。

## 参考案例

- [masterzorag/Z3735F-linux](https://github.com/masterzorag/Z3735F-linux) —— 同型号（Z3735F）实践，含完整构建命令与预编译引导器。
- [Ubuntu Launchpad #1341944](https://bugs.launchpad.net/ubuntu/+bug/1341944) —— 32 位 GRUB 引导 64 位 Ubuntu（Bay Trail / Switch 10）。
- [DietPi issue #7518](https://github.com/MichaIng/DietPi/issues/7518) —— 为老 Atom 设备补 32 位 EFI 支持。
- [askubuntu 392719](https://askubuntu.com/questions/392719) —— 从 Debian multi-arch ISO 取 `bootia32.efi` 与 `grub/i386-efi` 模块。
- [sturmflut: Installing Ubuntu on BayTrail tablets](https://sturmflut.github.io/) —— 32 位引导器 + 64 位内核的平板实践。
- [unix.stackexchange 155557](https://unix.stackexchange.com/questions/155557) —— Bay Trail 仅 32 位 UEFI 的处理。

## 许可

本仓库脚本与文档以 **GPL-2.0-or-later** 发布；构建产物 `grub2ia32.efi` / `grubx64.efi`
由 GRUB 2 生成，同样适用 **GPL-2.0-or-later**（见 [LICENSE](LICENSE)）。
