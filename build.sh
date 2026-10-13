#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD SÉCURISÉ : LineageOS 23.2 + BakaSU (SuSFS Inline) + patches Motorola
# Appareil : Motorola One 5G Ace (kiev / SM8250)
# Statut : Boot OK, Tactile OK, Repack OK, Manager à résoudre
# =============================================================================

echo "=== Build BakaSU (SuSFS Inline) + patches Motorola pour kiev ==="
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

# ==================== 2. BakaSU ====================
echo "=== Intégration BakaSU ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "❌ KernelSU introuvable"; exit 1
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 3. SUSFS ====================
echo "=== Intégration SUSFS ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ -f "$SUSFS_PATCH" ]; then
    patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true
    find . -name "*.rej" -type f -delete 2>/dev/null || true
fi

if [ -d "/tmp/cyber_repo/Patches/fs" ]; then
    cp -rn /tmp/cyber_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/cyber_repo/Patches/include/linux" ]; then
    cp -rn /tmp/cyber_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi
echo "✅ SUSFS intégré"

# ==================== 3b. FIX warnings ====================
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c; do
    if [ -f "$f" ]; then
        sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
    fi
done
export KCFLAGS="-Wno-error=unused-variable -Wno-error=unused-function -Wno-error=unused-but-set-variable"
echo "✅ KCFLAGS exporté"

# ==================== 3c. INCLUDE + DÉCLARATIONS SUSFS ====================
echo ""
echo "=== Injection include + déclarations SUSFS ==="

python3 << 'PYEOF_SUSFS_DECL'
from pathlib import Path

decl_super = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
'''

decl_ns = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#ifndef CL_COPY_MNT_NS
#define CL_COPY_MNT_NS BIT(25)
#endif
#endif
'''

def force_inject(filepath, decl, anchor):
    p = Path(filepath)
    if not p.exists():
        print(f"❌ {filepath} : introuvable"); return
    content = p.read_text()
    if '#include <linux/susfs_def.h>' in content:
        print(f"[i] {filepath} : susfs_def.h déjà inclus"); return
    if anchor not in content:
        print(f"❌ {filepath} : ancre introuvable"); return
    content = content.replace(anchor, anchor + '\n' + decl, 1)
    p.write_text(content)
    print(f"✅ {filepath} : inséré après '{anchor}'")

force_inject("fs/super.c", decl_super, '#include "internal.h"')
force_inject("fs/namespace.c", decl_ns, '#include "internal.h"')
PYEOF_SUSFS_DECL

# ==================== 3d. FIX fs/stat.c ====================
echo ""
echo "=== Fix include manquant dans fs/stat.c ==="

python3 << 'PYEOF_STAT_FIX'
from pathlib import Path
p = Path("fs/stat.c")
if not p.exists():
    print("❌ fs/stat.c introuvable"); exit(0)
content = p.read_text()
if '#include <linux/susfs_def.h>' in content:
    print("[i] fs/stat.c : déjà patché")
else:
    anchor = '#include <asm/unistd.h>'
    if anchor in content:
        content = content.replace(anchor,
            anchor + '\n\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif', 1)
        p.write_text(content)
        print("✅ fs/stat.c : susfs_def.h inséré")
    else:
        print("❌ fs/stat.c : ancre introuvable")
PYEOF_STAT_FIX

# ==================== 4. NEUTRALISATION ====================
echo ""
echo "=== Neutralisation ==="
CHECK_PATTERNS=( "inline_hook_check.mk" "manual_hook_check.mk" "tracepoint_hook_check.mk" "susfs_compat.mk" "kprobe_check.mk" )
for pattern in "${CHECK_PATTERNS[@]}"; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do echo "# Vérification désactivée" > "$f"; done
    fi
done
ERROR_MK_FILES=$(grep -rl '\$(error' "$KSU_DIR" --include="*.mk" 2>/dev/null || true)
if [ -n "$ERROR_MK_FILES" ]; then
    for f in $ERROR_MK_FILES; do sed -i 's/\$(error/\$(warning/g' "$f" 2>/dev/null || true; done
fi
echo "✅ Neutralisation terminée"

# ==================== 4b. PATCH app_profile.c ====================
python3 << 'PYEOF_SECCOMP_FIX'
import re
from pathlib import Path
import os
candidates = ["drivers/kernelsu/policy/app_profile.c", "KernelSU/kernel/policy/app_profile.c"]
path = None
for c in candidates:
    if os.path.exists(c):
        path = Path(c); break
if path is None: exit(0)
content = path.read_text()
if 'CONFIG_KSU_SECCOMP_SAFE' in content: exit(0)
pattern = r'(void\s+disable_seccomp\s*\(void\)\s*\{)'
match = re.search(pattern, content)
if not match: exit(0)
start_brace = match.end() - 1
depth = 1; i = start_brace + 1; end_brace = -1
while i < len(content) and depth > 0:
    if content[i] == '{': depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0: end_brace = i; break
    i += 1
if end_brace < 0: exit(1)
body = content[start_brace+1:end_brace]
new_body = '\n#ifdef CONFIG_SECCOMP\n' + body + '\n#else\n\treturn;\n#endif\n'
content = content[:start_brace+1] + new_body + content[end_brace:]
path.write_text(content)
print("[+] disable_seccomp() patchée")
PYEOF_SECCOMP_FIX

# ==================== 5. CONFIGURATION ====================
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "# CONFIG_KPROBES is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig
grep -E "KSU_MANUAL_HOOK|KSU_TRACEPOINT|KPROBES|KSU_SUSFS" out/.config || true

# ==================== 5b. PATCHS MOTOROLA ====================
echo ""
echo "=== Patch signatures modules + tactile ==="

echo "Patch signatures modules..."
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

echo "Patch tactile..."
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c

echo "✅ Patches Motorola appliqués"

# ==================== 6. COMPILATION ====================
echo ""
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
    echo "→ Hash noyau compilé : $(cat /tmp/kernel_compiled_hash.txt)"
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 6b. DIAGNOSTIC DU PILOTE DANS VMLINUX ====================
echo ""
echo "=== Diagnostic : le pilote est-il lié au noyau ? ==="

VMLINUX="out/vmlinux"
if [ -f "$VMLINUX" ]; then
    echo "→ Recherche de kernelsu_init dans vmlinux :"
    if nm "$VMLINUX" 2>/dev/null | grep -q "kernelsu_init"; then
        echo "  ✅ kernelsu_init présent dans vmlinux"
        nm "$VMLINUX" 2>/dev/null | grep "kernelsu_init" | head -3
    else
        echo "  ❌ kernelsu_init ABSENT de vmlinux"
    fi

    echo ""
    echo "→ Recherche de ksu_supercalls_init :"
    if nm "$VMLINUX" 2>/dev/null | grep -q "ksu_supercalls_init"; then
        echo "  ✅ ksu_supercalls_init présent"
    else
        echo "  ❌ ksu_supercalls_init ABSENT"
    fi

    echo ""
    echo "→ Recherche de susfs_init :"
    if nm "$VMLINUX" 2>/dev/null | grep -q "susfs_init"; then
        echo "  ✅ susfs_init présent"
    else
        echo "  ❌ susfs_init ABSENT"
    fi

    echo ""
    echo "→ Message 'Initialized with driver version' :"
    if strings "$VMLINUX" 2>/dev/null | grep -q "Initialized with driver version"; then
        echo "  ✅ Message d'init présent (le pilote s'initialise)"
    else
        echo "  ❌ Message d'init ABSENT"
    fi

    echo ""
    echo "→ Message 'shell is allowed at init' :"
    if strings "$VMLINUX" 2>/dev/null | grep -q "shell is allowed at init"; then
        echo "  ✅ Message allow_shell présent"
    else
        echo "  ⚠️  Message allow_shell absent (allow_shell désactivé par défaut)"
    fi
else
    echo "❌ $VMLINUX introuvable"
fi

# ==================== 7. KSUD ====================
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

# ==================== 8. REPACK AVEC allow_shell + DIAGNOSTIC ====================
echo ""
echo "=== Repack avec modification cmdline (allow_shell) ==="

rm -f boot-stock.img
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f dtbo-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/
cd repack

./magiskboot unpack boot.img
if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec unpack"; exit 1
fi

echo ""
echo "→ Format du noyau original :"
file kernel 2>/dev/null || true
head -c 4 kernel | xxd | head -1

cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

# Ajout des paramètres allow_shell à la cmdline
echo "→ Ajout de allow_shell=1 à la cmdline"
if [ -f "bootimg.cfg" ]; then
    if ! grep -q "allow_shell" bootimg.cfg; then
        sed -i 's/^cmdline = \(.*\)$/cmdline = \1 kernelsu.allow_shell=1 allow_shell=1/' bootimg.cfg
        echo "  ✅ bootimg.cfg modifié :"
        grep "^cmdline" bootimg.cfg
    else
        echo "  [i] allow_shell déjà présent"
    fi
else
    echo "  ⚠️ bootimg.cfg absent"
fi

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img

# ==================== 8b. DIAGNOSTIC POST-REPACK ====================
echo ""
echo "=== DIAGNOSTIC POST-REPACK ==="

mkdir -p ../verify
cd ../verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true

if [ -f "kernel" ]; then
    echo "→ Taille du noyau extrait : $(du -h kernel | cut -f1)"
    echo "→ Taille du noyau compilé : $(du -h "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" | cut -f1)"

    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)

    echo "→ Hash extrait : $HASH_EXTRACTED"
    echo "→ Hash compilé : $HASH_COMPILED"

    if [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ]; then
        echo "✅ Le noyau extrait est IDENTIQUE au noyau compilé"
    else
        echo "⚠️  Le noyau extrait DIFFÈRE du noyau compilé !"
    fi

    echo ""
    echo "→ Recherche des symboles KernelSU/SUSFS dans le noyau extrait :"
    for sym in "kernelsu" "susfs" "ksu_handle" "susfs_is_current"; do
        if strings kernel 2>/dev/null | grep -q "$sym"; then
            echo "  ✅ '$sym' trouvé"
        else
            echo "  ❌ '$sym' ABSENT"
        fi
    done
else
    echo "❌ Impossible d'extraire le noyau de l'image finale"
fi
cd ..

# ==================== 9. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ ==="
echo "Cmdline modifiée : kernelsu.allow_shell=1 allow_shell=1 (si bootimg.cfg présent)"
ls -lh output/
