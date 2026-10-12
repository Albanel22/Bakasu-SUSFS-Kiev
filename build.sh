#!/bin/bash
set -euo pipefail

# ============================================================
# Méthode Ravindu - type ReSukiSU + SUSFS (Manual Hook)
# Device: Motorola One 5G Ace (kiev / SM8250)
# Kernel: 4.19.325
# Target: LineageOS 23.2
# ============================================================

echo "=== Build ReSukiSU + SUSFS (méthode Ravindu / manual hook) ==="
echo "Appareil : Motorola One 5G Ace (kiev / SM8250)"
echo "Kernel   : 4.19.325"
echo "Build    : LineageOS 23.2"

# --- Config ---
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Stock boot images
BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

# --- Pré-requis ---
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential bc bison ccache flex libelf-dev libssl-dev \
    libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    clang llvm lld llvm-tools device-tree-compiler git curl wget \
    zip unzip python3 python3-pip mkbootimg

python3 -m pip install --quiet gdown

# --- Répertoires ---
cd "${GITHUB_WORKSPACE:-$PWD}"
mkdir -p out output
rm -rf kernel_sources ksud-src ksud final_boot.img boot-stock.img dtbo-stock.img repack || true

# ============================================================
# 1) CLONE KERNEL
# ============================================================
echo ""
echo "=== 1. Clonage du kernel LineageOS (lineage-23.2) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ============================================================
# 2) INTÉGRATION RE SUKISU via setup.sh
# ============================================================
echo ""
echo "=== 2. Intégration ReSukiSU via setup.sh ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "ERROR: Impossible de trouver KernelSU après setup.sh"
    exit 1
fi

echo "KSU_DIR détecté : $KSU_DIR"

# check KSU integration
if ! grep -q 'CONFIG_KSU' drivers/Makefile 2>/dev/null; then
    echo "ERROR: KSU non intégré dans drivers/Makefile"
    exit 1
fi

if ! grep -q 'source.*Kconfig' drivers/Kconfig 2>/dev/null; then
    echo "ERROR: KSU non intégré dans drivers/Kconfig"
    exit 1
fi

# ============================================================
# 3) HOOKS MANUELS RE SUKISU
# ============================================================
echo ""
echo "=== 3. Hooks manuels ReSukiSU ==="

# --- execveat ---
if ! grep -q "ksu_handle_execveat" fs/exec.c 2>/dev/null; then
  python3 <<'PY'
import re
path = "fs/exec.c"
with open(path, "r") as f:
    content = f.read()

if "ksu_execveat_hook" not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				 void *argv, void *envp, int *flags);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m:
        content = content[:m.end()] + extern_decl + "\n" + content[m.end():]

    old = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);'''
    new = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);

#ifdef CONFIG_KSU
	if (unlikely(ksu_execveat_hook))
		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	else
		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)

with open(path, "w") as f:
    f.write(content)
PY
fi

# --- setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c 2>/dev/null; then
  python3 <<'PY'
import re
path = "kernel/sys.c"
with open(path, "r") as f:
    content = f.read()

if "ksu_handle_setresuid" not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m:
        content = content[:m.end()] + extern_decl + "\n" + content[m.end():]

    hook = '''#ifdef CONFIG_KSU
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
'''
    markers = [
        '\tbool ruid_new, euid_new, suid_new;',
        '\tkuid_t kruid, keuid, ksuid;',
        '\tksuid = make_kuid(ns, suid);',
    ]
    inserted = False
    for marker in markers:
        if marker in content:
            content = content.replace(marker, marker + '\n' + hook, 1)
            inserted = True
            break
    if not inserted:
        raise RuntimeError("setresuid marker not found")

with open(path, "w") as f:
    f.write(content)
PY
fi

# --- sys_read ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c 2>/dev/null; then
  python3 <<'PY'
import re
path = "fs/read_write.c"
with open(path, "r") as f:
    content = f.read()

if "ksu_handle_sys_read" not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m:
        content = content[:m.end()] + extern_decl + "\n" + content[m.end():]

    old = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
    new = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)

with open(path, "w") as f:
    f.write(content)
PY
fi

# --- input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c 2>/dev/null; then
  python3 <<'PY'
import re
path = "drivers/input/input.c"
with open(path, "r") as f:
    content = f.read()

if "ksu_handle_input_handle_event" not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m:
        content = content[:m.end()] + extern_decl + "\n" + content[m.end():]

    old = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old in content:
        content = content.replace(old, new, 1)

with open(path, "w") as f:
    f.write(content)
PY
fi

# verification finale
for hook in \
  "ksu_handle_execveat:fs/exec.c" \
  "ksu_handle_setresuid:kernel/sys.c" \
  "ksu_handle_sys_read:fs/read_write.c" \
  "ksu_handle_input_handle_event:drivers/input/input.c"; do
    fn="${hook%%:*}"
    file="${hook##*:}"
    if grep -q "$fn" "$file" 2>/dev/null; then
        echo "  ✓ $fn présent dans $file"
    else
        echo "  ERROR : $fn absent dans $file"
        exit 1
    fi
done

# ============================================================
# 4) PATCH SECURE COMPAT / SECCOMP
# ============================================================
echo ""
echo "=== 4. Patches de compatibilité / seccomp ==="

# app_profile.c
python3 <<'PY'
import os, re
from pathlib import Path

candidates = ["drivers/kernelsu/policy/app_profile.c", "KernelSU/kernel/policy/app_profile.c"]
path = None
for c in candidates:
    if os.path.exists(c):
        path = Path(c)
        break

if path is not None:
    content = path.read_text()
    if "CONFIG_KSU_SECCOMP_SAFE" not in content:
        pattern = r'(void\s+disable_seccomp\s*\(void\)\s*\{)'
        m = re.search(pattern, content)
        if m:
            brace_start = m.end()-1
            depth = 1
            i = brace_start + 1
            end = -1
            while i < len(content) and depth > 0:
                if content[i] == '{':
                    depth += 1
                elif content[i] == '}':
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
                i += 1
            if end >= 0:
                body = content[brace_start+1:end]
                new_body = '\n#ifdef CONFIG_SECCOMP\n' + body + '\n#else\n\t/* CONFIG_KSU_SECCOMP_SAFE : seccomp désactivé, rien à faire */\n\treturn;\n#endif\n'
                content = content[:brace_start+1] + new_body + content[end:]
                path.write_text(content)
                print("app_profile patched")
PY

# kernel/seccomp.c
python3 <<'PY'
from pathlib import Path
import re

path = Path("kernel/seccomp.c")
if path.exists():
    content = path.read_text()
    if "CONFIG_KSU_SECCOMP_BYPASS" not in content:
        pattern = r'(int\s+__secure_computing\s*\([^)]+\)\s*\{[^}]*?int\s+this_syscall\s*;)'
        m = re.search(pattern, content, re.DOTALL)
        if m:
            pos = m.end()
            bypass = '''
#ifdef CONFIG_KSU
	/* bypass syscalls KernelSU/SUSFS */
	{
		int __ksu_nr = sd ? sd->nr : syscall_get_nr(current, task_pt_regs(current));
		if (__ksu_nr == __NR_reboot && sd) {
			if ((unsigned long)sd->args[0] == 0xDEADBEEFUL) {
				return 0;
			}
		}
	}
#endif
'''
            content = content[:pos] + bypass + content[pos:]
            path.write_text(content)
            print("seccomp bypass inserted")
PY

# ============================================================
# 5) CONFIGURATION KERNEL
# ============================================================
echo ""
echo "=== 5. Configuration du noyau ==="

mkdir -p out
make O=out LLVM=1 CROSS_COMPILE="${CROSS_COMPILE}" CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
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
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE="${CROSS_COMPILE}" CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" olddefconfig

if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "CONFIG_KSU_MANUAL_HOOK" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi

if grep -q "^CONFIG_KPROBES=y" out/.config; then
    sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config
fi

echo "=== Options finales KSU / KPROBES ==="
grep -E "KSU_MANUAL_HOOK|KPROBES" out/.config || true

# ============================================================
# 6) COMPILATION
# ============================================================
echo ""
echo "=== 6. Compilation du noyau ==="

make O=out LLVM=1 CROSS_COMPILE="${CROSS_COMPILE}" CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" -j"$(nproc)" Image 2>&1 | tee build.log

if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "ERROR: Build kernel failed"
    grep -iE "error:|fatal error:" build.log | head -30 || true
    exit 1
fi

echo "✅ Kernel compilé"
ls -lh out/arch/arm64/boot/

# ============================================================
# 7) COMPILATION KSUD
# ============================================================
echo ""
echo "=== 7. Compilation ksud (ReSukiSU) ==="
cd "${GITHUB_WORKSPACE:-$PWD}"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip -O android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="${GITHUB_WORKSPACE:-$PWD}/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

rm -rf ksud-src
git clone --depth=1 https://github.com/ReSukiSU/ReSukiSU.git ksud-src

cd ksud-src/userspace/ksud
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
if [ -z "$KSUD_BINARY" ]; then
    echo "ERROR: ksud non trouvé"
    exit 1
fi

cp "$KSUD_BINARY" "${GITHUB_WORKSPACE:-$PWD}/ksud"
chmod 755 "${GITHUB_WORKSPACE:-$PWD}/ksud"

echo "✅ ksud compilé"
ls -lh "${GITHUB_WORKSPACE:-$PWD}/ksud"

# ============================================================
# 8) STOCK BOOT + REPACK
# ============================================================
echo ""
echo "=== 8. Téléchargement des images stock et repack ==="

cd "${GITHUB_WORKSPACE:-$PWD}"

gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img || true

mkdir -p repack
cp boot-stock.img repack/boot.img

wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cd repack
./magiskboot unpack boot.img

if [ ! -f kernel ] || [ ! -f ramdisk.cpio ]; then
    echo "ERROR: unpack boot.img failed"
    exit 1
fi

cp "${GITHUB_WORKSPACE:-$PWD}/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud ${GITHUB_WORKSPACE:-$PWD}/ksud"

cp "${GITHUB_WORKSPACE:-$PWD}/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ============================================================
# 9) SORTIE
# ============================================================
echo ""
echo "=== 9. Sortie des artefacts ==="

mkdir -p output
cp final_boot.img output/ReSukiSU-SuSFS-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ || true
cp ksud output/ksud || true

ls -lh output/

echo "=== BUILD TERMINÉ ==="
echo "Noyau + ksud: ReSukiSU + SUSFS"
echo "Boot final: output/ReSukiSU-SuSFS-boot.img"
