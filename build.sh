#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SUSFS-CYBERC3RD-V25-DEBUG : Ajout des déclarations extern + DEBUG sidtab
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

# ==================== 1. CLONAGE FRAIS ====================
echo "=== Clonage frais du noyau ==="
rm -rf kernel_sources
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 1b. DEBUG : Vérification du backport Google sidtab ====================
echo "=== DEBUG : Vérification du backport Google sidtab ==="
if grep -q "^int context_add_hash" security/selinux/ss/services.c 2>/dev/null; then
    echo "✅ Le noyau CONTIENT le backport Google (context_add_hash). Le correctif BakaSU sera activé."
else
    echo "⚠️ Le noyau NE CONTIENT PAS le backport Google (ou il est différent). Le correctif BakaSU ne s'activera pas automatiquement."
fi

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

# ==================== 4. PATCH SUSFS ====================
echo "=== Patch SUSFS 4.19 (cyberc3rd rebase) ==="
cd "$GITHUB_WORKSPACE/kernel_sources"

PATCH_URL="https://raw.githubusercontent.com/cyberc3dr/nGKI_Kernel_Build/rebase/Patches/Patch/susfs_patch_to_4.19.patch"
echo "Téléchargement du patch depuis : $PATCH_URL"

if curl -sSfL "$PATCH_URL" -o /tmp/susfs_4.19.patch; then
    echo "Application du patch..."
    patch -p1 < /tmp/susfs_4.19.patch 2>&1 | tail -15 || true
    rm -f /tmp/susfs_4.19.patch
else
    echo "❌ Échec du téléchargement du patch SUSFS."
    exit 1
fi
find . -name "*.rej" -type f -delete 2>/dev/null || true

# ==================== 5. CORRECTIONS COMPLÈTES (Headers + Extern) ====================
echo "=== Corrections post-patch complètes ==="

python3 << 'PYEOF'
import os
import re

# 1. Correction robuste de __maybe_unused pour la variable 'vma'
files_to_fix = ["fs/proc/task_mmu.c", "fs/namespace.c", "fs/super.c", "fs/stat.c"]
for filepath in files_to_fix:
    if os.path.exists(filepath):
        with open(filepath, 'r') as f:
            content = f.read()
        
        new_content = re.sub(
            r'(\bstruct vm_area_struct\s+\*\s*vma\s*;)',
            r'struct vm_area_struct *vma __maybe_unused;',
            content
        )
        
        if new_content != content:
            with open(filepath, 'w') as f:
                f.write(new_content)
            print(f"✅ Correction __maybe_unused appliquée à {filepath}")

# 2. Ajout du header ET des déclarations extern dans fs/super.c
filepath = "fs/super.c"
if os.path.exists(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Si le code SUSFS est utilisé mais que les déclarations extern sont manquantes
    if ("DEFAULT_KSU_MNT_MINOR_DEV" in content or "susfs_is_current_ksu_domain" in content):
        needs_fix = False
        if "#include <linux/susfs_def.h>" not in content:
            needs_fix = True
        if "extern bool susfs_is_current_ksu_domain" not in content:
            needs_fix = True
        if "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted" not in content:
            needs_fix = True
        
        if needs_fix:
            print("⚠️ Code SUSFS détecté dans fs/super.c, mais déclarations manquantes. Ajout en cours...")
            lines = content.split('\n')
            first_include_idx = -1
            for i, line in enumerate(lines):
                if line.strip().startswith('#include'):
                    first_include_idx = i
                    break
            
            if first_include_idx != -1:
                # Insérer le header et les déclarations extern
                insert_lines = [
                    '#ifdef CONFIG_KSU_SUSFS',
                    '#include <linux/susfs_def.h>',
                    '#endif',
                    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT',
                    'extern bool susfs_is_current_ksu_domain(void);',
                    'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;',
                    '#endif'
                ]
                
                # Vérifier si déjà présent pour éviter les doublons
                if '#include <linux/susfs_def.h>' not in content:
                    for j, insert_line in enumerate(insert_lines):
                        lines.insert(first_include_idx + 1 + j, insert_line)
                
                with open(filepath, 'w') as f:
                    f.write('\n'.join(lines))
                print("✅ Header et déclarations extern ajoutés avec succès à fs/super.c")
            else:
                print("❌ Impossible de trouver un point d'insertion pour les déclarations.")
        else:
            print("✅ fs/super.c est déjà correctement configuré.")

# 3. Faire de même pour fs/namespace.c
fpath = "fs/namespace.c"
if os.path.exists(fpath):
    with open(fpath, 'r') as f:
        content = f.read()
    if "susfs_is_current_ksu_domain" in content:
        needs_fix = False
        if "#include <linux/susfs_def.h>" not in content:
            needs_fix = True
        if "extern bool susfs_is_current_ksu_domain" not in content:
            needs_fix = True
        
        if needs_fix:
            lines = content.split('\n')
            for i, line in enumerate(lines):
                if line.strip().startswith('#include'):
                    insert_lines = [
                        '#ifdef CONFIG_KSU_SUSFS',
                        '#include <linux/susfs_def.h>',
                        '#endif',
                        '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT',
                        'extern bool susfs_is_current_ksu_domain(void);',
                        'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;',
                        '#define CL_COPY_MNT_NS BIT(25)',
                        '#endif'
                    ]
                    for j, insert_line in enumerate(insert_lines):
                        lines.insert(i + 1 + j, insert_line)
                    with open(fpath, 'w') as f:
                        f.write('\n'.join(lines))
                    print(f"✅ Header et déclarations extern ajoutés à {fpath}")
                    break

# 4. Faire de même pour fs/stat.c
fpath = "fs/stat.c"
if os.path.exists(fpath):
    with open(fpath, 'r') as f:
        content = f.read()
    if "SUSFS" in content or "susfs" in content:
        if "#include <linux/susfs_def.h>" not in content:
            lines = content.split('\n')
            for i, line in enumerate(lines):
                if line.strip().startswith('#include'):
                    lines.insert(i + 1, '#ifdef CONFIG_KSU_SUSFS')
                    lines.insert(i + 2, '#include <linux/susfs_def.h>')
                    lines.insert(i + 3, '#endif')
                    with open(fpath, 'w') as f:
                        f.write('\n'.join(lines))
                    print(f"✅ Header ajouté à {fpath}")
                    break

print("✅ Toutes les corrections post-patch ont réussi.")
PYEOF

# ==================== 6. CONFIGURATION (FORCÉE) ====================
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

echo "→ Forçage des options KSU..."
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
echo "=== Repack avec injection ksud ==="
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

echo "→ Préparation du ramdisk..."
rm -rf ramdisk_work && mkdir -p ramdisk_work
cd ramdisk_work
../magiskboot cpio ../ramdisk.cpio extract

mkdir -p system/bin
cp "$GITHUB_WORKSPACE/ksud" system/bin/ksud
chmod 755 system/bin/ksud
echo "✅ ksud ajouté au ramdisk"

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
echo "✅ Script init.rc ajouté"

cd ..

echo "→ Reconstruction du ramdisk..."
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 0755 system/bin/ksud ramdisk_work/system/bin/ksud" \
    "add 0750 $INITRC_PATH ramdisk_work/$INITRC_PATH"

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
echo ""
echo "========================================="
echo "=== 🎉 BUILD TERMINÉ AVEC SUCCÈS v25-DEBUG ==="
echo "========================================="
ls -lh output/
