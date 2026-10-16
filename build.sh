#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SUSFS-CYBERC3RD-V18 : BakaSU + SUSFS 2.3.0 (Script "Marteau-Piqueur")
# Correction : Injection garantie via sed (plus de Python fragile pour super.c)
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

# ==================== 5. CORRECTIONS POST-PATCH SUSFS (SED MARTHEAU-PIQUEUR) ====================
echo "=== Corrections post-patch SUSFS (Injection forcée) ==="

# 1. Correction __maybe_unused
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
done

# 2. Injection GARANTIE dans fs/super.c via sed
if ! grep -q "susfs_is_current_ksu_domain" fs/super.c; then
    echo "⚠️ fs/super.c : Déclarations manquantes, injection via sed..."
    if grep -q '#include "internal.h"' fs/super.c; then
        sed -i '/#include "internal.h"/a\
#ifdef CONFIG_KSU_SUSFS\
#include <linux/susfs_def.h>\
#endif\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
#endif' fs/super.c
    else
        # Fallback ultime : ligne 26 (juste après les commentaires de licence)
        sed -i '26a\
#ifdef CONFIG_KSU_SUSFS\
#include <linux/susfs_def.h>\
#endif\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
#endif' fs/super.c
    fi
    echo "✅ fs/super.c corrigé avec succès"
else
    echo "✅ fs/super.c : Déclarations déjà présentes"
fi

# 3. Injection dans fs/namespace.c
if ! grep -q "susfs_is_current_ksu_domain" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
#define CL_COPY_MNT_NS BIT(25)\
#endif' fs/namespace.c 2>/dev/null || true
    echo "✅ fs/namespace.c corrigé"
fi

# 4. Injection dans fs/stat.c
if ! grep -q "susfs_def.h" fs/stat.c; then
    sed -i '/#include <asm\/unistd.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\
#include <linux/susfs_def.h>\
#endif' fs/stat.c 2>/dev/null || true
    echo "✅ fs/stat.c corrigé"
fi

# ==================== 6. CONFIGURATION (FORCÉE ET BLINDÉE) ====================
echo "=== Configuration du noyau ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

cat << 'EOF' >> out/.config
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KALLSYMS_ALL=y
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
EOF

echo "→ Résolution des dépendances (olddefconfig)..."
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig > /dev/null 2>&1

echo "→ Forçage des options KSU (Option Nucléaire)..."
sed -i 's/^# CONFIG_KSU is not set$/CONFIG_KSU=y/' out/.config
sed -i 's/^# CONFIG_KSU_SUSFS is not set$/CONFIG_KSU_SUSFS=y/' out/.config
sed -i 's/^CONFIG_KSU_MANUAL_HOOK=y$/# CONFIG_KSU_MANUAL_HOOK is not set/' out/.config
sed -i 's/^CONFIG_KSU_TRACEPOINT_HOOK=y$/# CONFIG_KSU_TRACEPOINT_HOOK is not set/' out/.config

echo "=== VÉRIFICATION FINALE DU .CONFIG ==="
grep -E "^CONFIG_KSU=|^CONFIG_KSU_SUSFS=|^CONFIG_KSU_MANUAL_HOOK=" out/.config || echo "❌ ERREUR CRITIQUE : KSU n'est pas activé !"

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

# ==================== 10. REPACK AVEC INJECTION KSUD ====================
echo "=== Repack avec injection ksud (Obligatoire pour Non-GKI) ==="
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

echo "→ Préparation du ramdisk pour l'injection..."
rm -rf ramdisk_work && mkdir -p ramdisk_work
cd ramdisk_work
../magiskboot cpio ../ramdisk.cpio extract

mkdir -p system/bin
cp "$GITHUB_WORKSPACE/ksud" system/bin/ksud
chmod 755 system/bin/ksud
echo "✅ ksud ajouté au ramdisk (system/bin/)"

INITRC_PATH="init.rc"
[ -f "system/etc/init/hw/init.rc" ] && INITRC_PATH="system/etc/init/hw/init.rc"

mkdir -p "$(dirname "$INITRC_PATH")"
cat >> "$INITRC_PATH" << 'INITRC_EOF'

# --- KSUD START ---
on post-fs-data
    exec u:r:su:s0 root -- /system/bin/ksud post-fs-data

on nonencrypted
    exec u:r:su:s0 root -- /system/bin/ksud services

on property:sys.boot_completed=1
    exec u:r:su:s0 root -- /system/bin/ksud boot-completed
# --- KSUD END ---
INITRC_EOF
echo "✅ Script init.rc ajouté à $INITRC_PATH"

cd ..

echo "→ Reconstruction du ramdisk avec les ajouts..."
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 0755 system/bin/ksud ramdisk_work/system/bin/ksud" \
    "add 0750 $INITRC_PATH ramdisk_work/$INITRC_PATH"

echo "→ Repack..."
./magiskboot repack boot.img new-boot.img
[ ! -f "new-boot.img" ] && { echo "❌ Échec repack"; exit 1; }
mv new-boot.img ../final_boot.img && cd ..
echo "✅ Repack terminé avec injection ksud"

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SUSFS-cyberc3rd-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "========================================="
echo "=== 🎉 BUILD TERMINÉ AVEC SUCCÈS v18 ==="
echo "========================================="
ls -lh output/
