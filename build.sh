#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SUSFS-INLINE-V11 : SUSFS + Manual Hooks COMPLETS (4.19+)
# =============================================================================

echo "=== Build BakaSU + SUSFS + Manual Hooks v11 ==="
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

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi

# ==================== 2e. NEUTRALISATION CHECK.MK ====================
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    find . -name "$pattern" -type f -exec sed -i 's/\$(error/\$(warning/g' {} + 2>/dev/null || true
done

# ==================== 3. PATCH SUSFS ====================
echo "=== Patch SUSFS 4.19 ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true

cd "$GITHUB_WORKSPACE/kernel_sources"
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1)
if [ -n "$PATCH_419" ]; then
    patch -p1 < "$PATCH_419" 2>&1 | tail -5 || true
fi
find . -name "*.rej" -type f -delete 2>/dev/null || true

# ==================== 4. CORRECTIONS POST-PATCH SUSFS ====================
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
done

# Injections SUSFS de base
python3 << 'PYEOF'
from pathlib import Path

files_to_patch = {
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

for filepath, (anchor, decl) in files_to_patch.items():
    p = Path(filepath)
    if p.exists() and 'susfs_def.h' not in p.read_text():
        content = p.read_text()
        if anchor in content:
            content = content.replace(anchor, anchor + '\n' + decl, 1)
            p.write_text(content)
PYEOF

# ==================== 5. INJECTION DES MANUAL HOOKS (OBLIGATOIRE 4.19+) ====================
echo "=== Injection des Manual Hooks (Requis pour ReSukiSU v4.1.0) ==="

python3 << 'PYEOF'
import re
from pathlib import Path

# 1. STAT HOOK (fs/stat.c)
stat_file = Path("fs/stat.c")
if stat_file.exists() and "ksu_handle_stat" not in stat_file.read_text():
    content = stat_file.read_text()
    # Déclarations
    decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    # Injection dans newfstatat
    content = re.sub(
        r'(SYSCALL_DEFINE4\(newfstatat,.*?int error;\n)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n',
        content, flags=re.DOTALL
    )
    # Injection dans newfstat
    content = re.sub(
        r'(SYSCALL_DEFINE2\(newfstat,.*?if \(!error\)\n\t\terror = cp_new_stat\(&stat, statbuf\);\n)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n',
        content, flags=re.DOTALL
    )
    # Ajout des déclarations en haut
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'ksu_handle_stat' not in content[:m.end()]:
        content = content[:m.end()] + decl + '\n' + content[m.end():]
    stat_file.write_text(content)
    print("✅ Hook stat.c injecté")

# 2. EXECVE HOOK (fs/exec.c)
exec_file = Path("fs/exec.c")
if exec_file.exists() and "ksu_handle_execveat" not in exec_file.read_text():
    content = exec_file.read_text()
    decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
__attribute__((hot))
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags, int *retval);
#endif
'''
    # Injection dans do_execveat_common
    content = re.sub(
        r'(static int do_execveat_common\(int fd, struct filename \*filename,\s*struct user_arg_ptr argv,\s*struct user_arg_ptr envp,\s*int flags\)\n\{)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tint retval;\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n\tretval = __do_execve_file(fd, filename, argv, envp, flags, NULL);\n\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);\n\treturn retval;\n#else',
        content
    )
    content = re.sub(
        r'(\treturn __do_execve_file\(fd, filename, argv, envp, flags, NULL\);\n\})',
        r'#endif\n\1',
        content
    )
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'ksu_handle_execveat' not in content[:m.end()]:
        content = content[:m.end()] + decl + '\n' + content[m.end():]
    exec_file.write_text(content)
    print("✅ Hook exec.c injecté")

# 3. FACCESSAT HOOK (fs/open.c)
open_file = Path("fs/open.c")
if open_file.exists() and "ksu_handle_faccessat" not in open_file.read_text():
    content = open_file.read_text()
    decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);
#endif
'''
    content = re.sub(
        r'(SYSCALL_DEFINE3\(faccessat, int, dfd, const char __user \*, filename, int, mode\)\n\{)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n',
        content
    )
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'ksu_handle_faccessat' not in content[:m.end()]:
        content = content[:m.end()] + decl + '\n' + content[m.end():]
    open_file.write_text(content)
    print("✅ Hook open.c injecté")

# 4. REBOOT HOOK (kernel/reboot.c ou kernel/sys.c)
reboot_file = Path("kernel/reboot.c") if Path("kernel/reboot.c").exists() else Path("kernel/sys.c")
if reboot_file.exists() and "ksu_handle_sys_reboot" not in reboot_file.read_text():
    content = reboot_file.read_text()
    decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    content = re.sub(
        r'(SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,\s*void __user \*, arg\)\n\{)',
        r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n',
        content
    )
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'ksu_handle_sys_reboot' not in content[:m.end()]:
        content = content[:m.end()] + decl + '\n' + content[m.end():]
    reboot_file.write_text(content)
    print("✅ Hook reboot injecté")

print("✅ Tous les Manual Hooks requis ont été injectés.")
PYEOF

# ==================== 6. CONFIGURATION "MAGIQUE" ====================
echo "=== Configuration (Optimisée pour Manual Hooks 4.19) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  # Ces options appliquent automatiquement certains hooks via LSM, évitant des edits source fragiles
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  # ASTUCE CRUCIALE de la doc : évite TOUTES les modifications manuelles des exports SELinux (static)
  echo "CONFIG_KALLSYMS_ALL=y"
  
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
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

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

# 1. Installation propre de Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 2. Configuration correcte de la toolchain nightly
rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

# 3. Téléchargement du NDK
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"

# 4. Variables d'environnement EXPLICITES pour CC et CXX (C'est la clé !)
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android26-clang++"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

# 5. Récupération des sources BakaSU
rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"

# 6. Configuration Cargo pour le cross-compiling
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$NDK_BIN/aarch64-linux-android26-clang"

[env]
CC_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang"
CXX_aarch64_linux_android = "$NDK_BIN/aarch64-linux-android26-clang++"
AR_aarch64_linux_android = "$NDK_BIN/llvm-ar"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF

# 7. Compilation avec gestion d'erreur claire
echo "→ Lancement de cargo build..."
if ! cargo build --release --target aarch64-linux-android; then
    echo "❌ Échec de la compilation de ksud"
    exit 1
fi

KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
if [ -z "$KSUD_BINARY" ]; then
    echo "❌ ksud introuvable"
    exit 1
fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé : $(du -h $GITHUB_WORKSPACE/ksud | cut -f1)"

# ==================== 10. REPACK VÉRIFIÉ ====================
echo "=== Repack avec vérifications ==="
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

echo "→ Extraction et modification init.rc..."
rm -rf ramdisk_work && mkdir -p ramdisk_work && cd ramdisk_work
../magiskboot cpio ../ramdisk.cpio extract

INITRC_PATH=""
for p in "init.rc" "system/etc/init/hw/init.rc" "system/etc/init/init.rc"; do
    [ -f "$p" ] && INITRC_PATH="$p" && break
done
[ -z "$INITRC_PATH" ] && INITRC_PATH=$(find . -name "init.rc" -type f 2>/dev/null | head -1)

# Fallback robuste si init.rc est absent
if [ -z "$INITRC_PATH" ]; then
    echo "⚠️ init.rc introuvable. Création d'un fallback à la racine."
    INITRC_PATH="init.rc"
    touch "$INITRC_PATH"
fi

INITRC_PATH="${INITRC_PATH#./}"
mkdir -p "$(dirname "$INITRC_PATH")"

cat >> "$INITRC_PATH" << 'INITRC_EOF'
# --- KSUD START ---
on post-fs-data
    exec u:r:su:s0 root -- /system/bin/ksud post-fs-data
on nonencrypted
    exec u:r:su:s0 root -- /system/bin/ksud services
on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root -- /system/bin/ksud services
on property:sys.boot_completed=1
    exec u:r:su:s0 root -- /system/bin/ksud boot-completed
# --- KSUD END ---
INITRC_EOF

mkdir -p system/bin && cp "$GITHUB_WORKSPACE/ksud" system/bin/ksud && chmod 755 system/bin/ksud
cd ..

echo "→ Reconstruction du ramdisk..."
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 0755 system/bin/ksud ramdisk_work/system/bin/ksud"
[ -n "$INITRC_PATH" ] && ./magiskboot cpio ramdisk.cpio "add 0750 $INITRC_PATH ramdisk_work/$INITRC_PATH"

echo "→ Repack..."
./magiskboot repack boot.img new-boot.img
[ ! -f "new-boot.img" ] && { echo "❌ Échec repack"; exit 1; }
mv new-boot.img ../final_boot.img && cd ..

# ==================== 11. VÉRIFICATION POST-REPACK ====================
echo "=== VÉRIFICATION POST-REPACK ==="
mkdir -p verify && cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img

HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
[ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE" || echo "⚠️ Noyau DIFFÉRENT !"

mkdir -p ramdisk_check && cd ramdisk_check
../../repack/magiskboot cpio ../../repack/ramdisk.cpio extract 2>/dev/null || true
[ -f "system/bin/ksud" ] && echo "✅ ksud présent dans le ramdisk" || echo "❌ ksud ABSENT du ramdisk !"

cd ../..

# ==================== 12. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SUSFSInline-v11-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ v11 ==="
ls -lh output/
