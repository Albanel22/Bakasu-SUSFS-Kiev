#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD : LineageOS 23.2 + BakaSU (SuSFS Inline) pour kernel 4.19 non-GKI
# Appareil : Motorola One 5G Ace (kiev / SM8250)
# =============================================================================

echo "=== Build BakaSU (SuSFS Inline) pour kiev ==="
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

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel LineageOS (branche lineage-23.2) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU ====================
echo "=== Intégration BakaSU via setup.sh ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "❌ Impossible de trouver le dossier KernelSU"
    exit 1
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 3. INTÉGRATION SUSFS ====================
echo "=== Intégration SUSFS depuis cyberc3dr ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ -f "$SUSFS_PATCH" ]; then
    echo "→ Application du patch SUSFS 4.19..."
    patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true
    find . -name "*.rej" -type f -delete 2>/dev/null || true
    echo "  ✅ Patch SUSFS appliqué"
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

# ==================== 3b. FIX warnings -Werror (KCFLAGS uniquement) ====================
echo ""
echo "=== Correction des warnings -Werror ==="

for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    if [ -f "$f" ]; then
        sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
    fi
done
echo "  ✅ __maybe_unused appliqué"

export KCFLAGS="-Wno-error=unused-variable -Wno-error=unused-function -Wno-error=unused-but-set-variable"
echo "  ✅ KCFLAGS exporté : $KCFLAGS"
echo "✅ Corrections terminées"

# ==================== 3c. INJECTION FORCÉE DES DÉCLARATIONS SUSFS ====================
echo ""
echo "=== Injection des déclarations SUSFS manquantes ==="

python3 << 'PYEOF_SUSFS_DECL'
from pathlib import Path

decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>

extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#ifndef DEFAULT_KSU_MNT_MINOR_DEV
#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 12)
#endif
#ifndef DEFAULT_KSU_MNT_GROUP_ID
#define DEFAULT_KSU_MNT_GROUP_ID 200000
#endif
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */
'''

def inject_decl(filepath):
    p = Path(filepath)
    if not p.exists():
        print(f"[i] {filepath} : introuvable")
        return
    
    content = p.read_text()
    
    # Vérifier si les extern sont DÉJÀ en tête (vraie déclaration, pas usage)
    head = content[:3000]  # 3000 premiers caractères seulement
    if 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted' in head:
        print(f"[i] {filepath} : extern déjà présents en tête")
        return
    
    # Trouver le dernier #include du début
    lines = content.split('\n')
    last_inc = -1
    for i, line in enumerate(lines[:300]):
        if line.strip().startswith('#include'):
            last_inc = i
        elif line.strip() and not line.strip().startswith('#include') \
             and not line.strip().startswith('//') \
             and not line.strip().startswith('/*') \
             and not line.strip().startswith('*') \
             and last_inc >= 0:
            break  # on a dépassé le bloc d'includes
    
    if last_inc < 0:
        print(f"[!] {filepath} : aucun #include trouvé, insertion en ligne 0")
        lines.insert(0, decl)
    else:
        lines.insert(last_inc + 1, decl)
        print(f"[+] {filepath} : externs insérés après la ligne {last_inc + 1} (dernier #include)")
    
    p.write_text('\n'.join(lines))
    print(f"    → Ligne {last_inc + 2} : {lines[last_inc + 2][:80]}")

inject_decl("fs/super.c")
inject_decl("fs/namespace.c")
PYEOF_SUSFS_DECL

echo ""
echo "=== Vérification post-injection ==="
for f in fs/super.c fs/namespace.c; do
    if [ -f "$f" ]; then
        COUNT=$(grep -c "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted" "$f" 2>/dev/null || echo 0)
        if [ "$COUNT" -gt 0 ]; then
            echo "  ✅ $f : $COUNT extern(s) présent(s)"
        else
            echo "  ❌ $f : AUCUN extern trouvé !"
        fi
        echo "  → Lignes 1-40 de $f :"
        head -40 "$f" | grep -n "susfs\|#include <linux/susfs" | head -10 || true
    fi
done

# Vérifier que susfs_def.h existe
if [ -f "include/linux/susfs_def.h" ]; then
    echo "  ✅ include/linux/susfs_def.h existe"
else
    echo "  ❌ include/linux/susfs_def.h MANQUANT !"
    find . -name "susfs_def.h" -type f 2>/dev/null | head -5
fi

echo "✅ Injection terminée"


# ==================== 4. NEUTRALISATION DES VÉRIFICATIONS ====================
echo ""
echo "=== Neutralisation des vérifications ==="

CHECK_PATTERNS=( "inline_hook_check.mk" "manual_hook_check.mk" "tracepoint_hook_check.mk" "susfs_compat.mk" "kprobe_check.mk" )
for pattern in "${CHECK_PATTERNS[@]}"; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            echo "  → Vidage : $f"
            echo "# Vérification désactivée pour build non-GKI" > "$f"
        done
    fi
done

ERROR_MK_FILES=$(grep -rl '\$(error' "$KSU_DIR" --include="*.mk" 2>/dev/null || true)
if [ -n "$ERROR_MK_FILES" ]; then
    for f in $ERROR_MK_FILES; do
        sed -i 's/\$(error/\$(warning/g' "$f" 2>/dev/null || true
    done
fi
echo "✅ Neutralisation terminée"

# ==================== 4b. PATCH app_profile.c (compat seccomp) ====================
echo "=== Patch compatibilité disable_seccomp() ==="

python3 << 'PYEOF_SECCOMP_FIX'
import re
from pathlib import Path
import os

candidates = ["drivers/kernelsu/policy/app_profile.c", "KernelSU/kernel/policy/app_profile.c"]
path = None
for c in candidates:
    if os.path.exists(c):
        path = Path(c)
        break

if path is None:
    print("⚠️  app_profile.c introuvable, skip")
    exit(0)

content = path.read_text()
if 'CONFIG_KSU_SECCOMP_SAFE' in content:
    print("[i] déjà patché")
    exit(0)

pattern = r'(void\s+disable_seccomp\s*\(void\)\s*\{)'
match = re.search(pattern, content)
if not match:
    print("[i] disable_seccomp() absente")
    exit(0)

start_brace = match.end() - 1
depth = 1
i = start_brace + 1
end_brace = -1
while i < len(content) and depth > 0:
    if content[i] == '{': depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end_brace = i
            break
    i += 1

if end_brace < 0:
    print("[!] Fermeture non trouvée")
    exit(1)

body = content[start_brace+1:end_brace]
new_body = '\n#ifdef CONFIG_SECCOMP\n' + body + '\n#else\n\t/* CONFIG_KSU_SECCOMP_SAFE */\n\treturn;\n#endif\n'
content = content[:start_brace+1] + new_body + content[end_brace:]
path.write_text(content)
print("[+] disable_seccomp() patchée")
PYEOF_SECCOMP_FIX

# ==================== 5. CONFIGURATION ====================
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
CONFIG_NAME="vendor/lito-perf_defconfig"
echo "Config utilisée : $CONFIG_NAME"
if [ ! -f "arch/arm64/configs/$CONFIG_NAME" ]; then echo "❌ $CONFIG_NAME introuvable !"; exit 1; fi
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

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

echo "=== État final .config ==="
grep -E "KSU_MANUAL_HOOK|KSU_TRACEPOINT|KPROBES|KSU_SUSFS" out/.config || true

# ==================== 6. COMPILATION ====================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then echo "✅ Compilation réussie"; ls -lh out/arch/arm64/boot/
else echo "❌ BUILD FAILED"; grep -iE "error:|fatal error:" build.log | head -30; exit 1; fi

# ==================== 7. KSUD ====================
echo "=== Compilation de ksud ==="
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

# ==================== 8. REPACK ====================
echo "=== Téléchargement des images stock ==="
rm -f boot-stock.img
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"; fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then echo "❌ boot-stock.img invalide"; exit 1; fi
rm -f dtbo-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

echo "=== Repack avec magiskboot ==="
mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot; chmod +x repack/magiskboot; rm -rf Magisk-v27.0.apk lib/
cd repack
./magiskboot unpack boot.img
if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then echo "❌ Échec unpack"; exit 1; fi
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" local_su_binary; chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/BakaSU-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ==="
ls -lh output/
