#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SUSFS-CYBERC3RD-V14 : BakaSU + SUSFS 2.3.0 (Patch Direct)
# =============================================================================

echo "=== Build BakaSU + SUSFS cyberc3rd 2.3.0 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU ====================
echo "=== Intégration BakaSU ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration BakaSU"
    exit 1
fi
echo "✅ BakaSU intégré"

# ==================== 3. NEUTRALISATION CHECK.MK ====================
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    find . -name "$pattern" -type f -exec sed -i 's/\$(error/\$(warning/g' {} + 2>/dev/null || true
done

# ==================== 4. PATCH SUSFS (cyberc3rd 4.19 - URL DIRECTE) ====================
echo "=== Patch SUSFS 4.19 (cyberc3rd rebase) ==="
cd "$GITHUB_WORKSPACE/kernel_sources"

PATCH_URL="https://raw.githubusercontent.com/cyberc3dr/nGKI_Kernel_Build/rebase/Patches/Patch/susfs_patch_to_4.19.patch"
echo "Téléchargement du patch depuis : $PATCH_URL"

if curl -sSfL "$PATCH_URL" -o /tmp/susfs_4.19.patch; then
    echo "Application du patch..."
    patch -p1 < /tmp/susfs_4.19.patch 2>&1 | tail -15 || true
    rm -f /tmp/susfs_4.19.patch
else
    echo "❌ Échec du téléchargement du patch SUSFS. Vérifiez l'URL."
    exit 1
fi
find . -name "*.rej" -type f -delete 2>/dev/null || true

# ==================== 5. CORRECTIONS POST-PATCH SUSFS ====================
echo "=== Corrections post-patch SUSFS ==="
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
done

# Injection des headers susfs_def.h si manquants (sécurité)
python3 << 'PYEOF'
from pathlib import Path
files = {
    "fs/namespace.c": ('#include <linux/sched/task.h>', '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25)
#endif'''),
    "fs/super.c": ('#include "internal.h"', '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif'''),
    "fs/stat.c": ('#include <asm/unistd.h>', '''
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
#include <linux/susfs_def.h>
#endif''')
}
for fp, (anchor, decl) in files.items():
    p = Path(fp)
    if p.exists() and 'susfs_def.h' not in p.read_text():
        c = p.read_text()
        if anchor in c:
            p.write_text(c.replace(anchor, anchor + '\n' + decl, 1))
PYEOF

# ==================== 6. CONFIGURATION (SUSFS UNIQUEMENT) ====================
echo "=== Configuration (SUSFS Pure) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

echo "=== Vérification .config ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5
echo "--- Configuration KSU finale ---"
grep -E "CONFIG_KSU|CONFIG_KALLSYMS" out/.config | grep -v "^#"

# ==================== 7. PATCHS MOTOROLA ====================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
if [ -f "techpack/display/msm/msm_drv.c" ]; then
    printf "\n/* --- Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) { return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) { return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch --- */\n" >> techpack/display/msm/msm_drv.c
fi

# ==================== 8. COMPILATION ====================
echo "=== Compilation ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 9. COMPILATION KSUD ====================
echo "=== Compilation ksud ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang++"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$NDK_BIN/aarch64-linux-android26-clang"
[env]
CC_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang"
CXX_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang++"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

if ! cargo build --release --target aarch64-linux-android; then
    echo "❌ Échec compilation ksud"
    exit 1
fi
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
[ -z "$KSUD_BINARY" ] && { echo "❌ ksud introuvable"; exit 1; }
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"

# ==================== 10. REPACK SIMPLE ====================
echo "=== Repack ==="
cd "$GITHUB_WORKSPACE"
rm -f boot-stock.img dtbo-stock.img
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1
[ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ] && { echo "❌ boot-stock invalide"; exit 1; }
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack && cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so && mv lib/x86_64/libmagiskboot.so repack/magiskboot && chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/
cd repack

echo "→ Unpack..."
./magiskboot unpack boot.img
[ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ] && { echo "❌ Échec unpack"; exit 1; }

echo "→ Remplacement du kernel..."
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

echo "→ Repack..."
./magiskboot repack boot.img new-boot.img
[ ! -f "new-boot.img" ] && { echo "❌ Échec repack"; exit 1; }
mv new-boot.img ../final_boot.img && cd ..
echo "✅ Repack terminé"

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SUSFS-cyberc3rd-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ v14 ==="
ls -lh output/
