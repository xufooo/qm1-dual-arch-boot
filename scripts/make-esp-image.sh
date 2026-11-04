#!/usr/bin/env bash
# make-esp-image.sh — 生成可直接写盘的 FAT32 ESP 启动镜像（双引导器 + grub.cfg + 内核）
#
# 用法：
#   bash scripts/make-esp-image.sh --out out/qm1-dual-boot.img \
#        --bootloaders out --root-uuid 11111111-2222-3333-4444-555555555555 \
#        [--root32-uuid ...] [--kernel vmlinuz] [--initrd initrd.img] \
#        [--kernel32 vmlinuz-32] [--initrd32 initrd-32.img] [--size-mib 512]
#
# 产出布局（UEFI 可移动介质规范路径）：
#   /EFI/BOOT/BOOTIA32.EFI   ← grub2ia32.efi（PE32/IA32）
#   /EFI/BOOT/BOOTX64.EFI    ← grubx64.efi （PE32+/x86-64）
#   /EFI/BOOT/grub.cfg       ← 由 scripts/grub.cfg.example 生成
#   /vmlinuz  /initrd.img       （64 位内核）
#   /vmlinuz-32 /initrd-32.img  （32 位内核，可选）
#
# 后端优先级：mtools（无需 root）→ loop 挂载（需要 root）
set -euo pipefail

OUT=""; SIZE_MIB=512; BOOTDIR="out"
ROOT_UUID=""; ROOT32_UUID=""
KERNEL=""; INITRD=""; KERNEL32=""; INITRD32=""
LABEL="QM1ESP"

die() { printf '[esp] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[esp] %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="$2"; shift 2 ;;
        --size-mib)   SIZE_MIB="$2"; shift 2 ;;
        --bootloaders) BOOTDIR="$2"; shift 2 ;;
        --root-uuid)  ROOT_UUID="$2"; shift 2 ;;
        --root32-uuid) ROOT32_UUID="$2"; shift 2 ;;
        --kernel)     KERNEL="$2"; shift 2 ;;
        --initrd)     INITRD="$2"; shift 2 ;;
        --kernel32)   KERNEL32="$2"; shift 2 ;;
        --initrd32)   INITRD32="$2"; shift 2 ;;
        --label)      LABEL="$2"; shift 2 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -n "$OUT" ]          || die "缺少 --out"
[ -n "$ROOT_UUID" ]    || die "缺少 --root-uuid（64 位根分区 UUID）"
[ -f "$BOOTDIR/grub2ia32.efi" ] || die "缺少 $BOOTDIR/grub2ia32.efi（先跑 build-bootloaders.sh）"
[ -f "$BOOTDIR/grubx64.efi" ]  || die "缺少 $BOOTDIR/grubx64.efi"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_TEMPLATE="$SCRIPT_DIR/grub.cfg.example"
[ -f "$CFG_TEMPLATE" ] || die "找不到 grub.cfg 模板: $CFG_TEMPLATE"

mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] && die "输出已存在，拒绝覆盖: $OUT"

# ---------- grub.cfg 生成 ----------
cfg="$(sed -e "s|@ROOT_UUID@|$ROOT_UUID|g" -e "s|@ROOT32_UUID@|${ROOT32_UUID:-00000000-0000-0000-0000-000000000000}|g" "$CFG_TEMPLATE")"
if [ -z "$ROOT32_UUID" ]; then
    # 没有 32 位根分区时移除 32 位菜单项，避免留一个必然失败的条目
    cfg="$(printf '%s\n' "$cfg" | awk '
        /menuentry "QM1 Debian 13 \(32-bit i386\)"/ { skip=1 }
        skip && /^}/ { skip=0; next }
        skip { next }
        { print }')"
fi
CFG_TMP="$(mktemp)"; printf '%s\n' "$cfg" > "$CFG_TMP"

# ---------- 写入 FAT32 ----------
if command -v mformat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
    log "后端: mtools（无需 root）"
    dd if=/dev/zero of="$OUT" bs=1M count="$SIZE_MIB" status=none
    mformat -i "$OUT" -F -v "$LABEL" :: >/dev/null
    mmd -i "$OUT" ::/EFI ::/EFI/BOOT
    mcopy -i "$OUT" "$BOOTDIR/grub2ia32.efi" ::/EFI/BOOT/BOOTIA32.EFI
    mcopy -i "$OUT" "$BOOTDIR/grubx64.efi"  ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$OUT" "$CFG_TMP"                ::/EFI/BOOT/grub.cfg
    [ -n "$KERNEL"   ] && mcopy -i "$OUT" "$KERNEL"   ::/vmlinuz
    [ -n "$INITRD"   ] && mcopy -i "$OUT" "$INITRD"   ::/initrd.img
    [ -n "$KERNEL32" ] && mcopy -i "$OUT" "$KERNEL32" ::/vmlinuz-32
    [ -n "$INITRD32" ] && mcopy -i "$OUT" "$INITRD32" ::/initrd-32.img
elif command -v mkfs.vfat >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    log "后端: loop 挂载（root）"
    truncate -s "${SIZE_MIB}M" "$OUT"
    mkfs.vfat -F 32 -n "$LABEL" "$OUT" >/dev/null
    MNT="$(mktemp -d)"
    mount -o loop,rw "$OUT" "$MNT"
    trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; rm -f "$CFG_TMP"' EXIT
    mkdir -p "$MNT/EFI/BOOT"
    cp "$BOOTDIR/grub2ia32.efi" "$MNT/EFI/BOOT/BOOTIA32.EFI"
    cp "$BOOTDIR/grubx64.efi"  "$MNT/EFI/BOOT/BOOTX64.EFI"
    cp "$CFG_TMP"               "$MNT/EFI/BOOT/grub.cfg"
    [ -n "$KERNEL"   ] && cp "$KERNEL"   "$MNT/vmlinuz"
    [ -n "$INITRD"   ] && cp "$INITRD"   "$MNT/initrd.img"
    [ -n "$KERNEL32" ] && cp "$KERNEL32" "$MNT/vmlinuz-32"
    [ -n "$INITRD32" ] && cp "$INITRD32" "$MNT/initrd-32.img"
    sync; umount "$MNT"; rmdir "$MNT"
    trap 'rm -f "$CFG_TMP"' EXIT
else
    die "需要 mtools（apt install mtools / pacman -S mtools），或以 root 运行以使用 loop 挂载"
fi

rm -f "$CFG_TMP"
sha256sum "$OUT" | tee "$OUT.sha256"
log "完成: $OUT"
log "写盘: dd if=$OUT of=/dev/<目标设备> bs=4M conv=fsync status=progress"
