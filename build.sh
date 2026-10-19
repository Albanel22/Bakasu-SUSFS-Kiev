#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# V27 — BakaSU sync-susfs / Linux 4.19 / Motorola One 5G Ace (kiev)
# Strict patch/config/build/repack checks. No silent patch failures, no global
# O_CLOEXEC rewrite, no automatic SELinux visibility changes, no seccomp-cache
# call on Linux < 5.10.

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="$ROOT_DIR/kernel_sources"
OUTPUT_DIR="$ROOT_DIR/output"
WORK_DIR="$ROOT_DIR/work_v27"
REPACK_DIR="$WORK_DIR/repack"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_motorola_sm8250.git}"
KERNEL_REF="${KERNEL_REF:-lineage-23.2}"
BAKASU_SETUP_URL="${BAKASU_SETUP_URL:-https://raw.githubusercontent.com/Baka-SU/BakaSU/sync-susfs/kernel/setup.sh}"
SUSFS_PATCH_REPO="${SUSFS_PATCH_REPO:-https://github.com/cyberc3dr/nGKI_Kernel_Build.git}"
SUSFS_PATCH_REF="${SUSFS_PATCH_REF:-rebase}"
BOOT_GDRIVE_ID="${BOOT_GDRIVE_ID:-1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis}"
DTBO_GDRIVE_ID="${DTBO_GDRIVE_ID:-11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX}"
DEFCONFIG="${DEFCONFIG:-vendor/lito-perf_defconfig}"
JOBS="${JOBS:-$(nproc)}"
NDK_VERSION="${NDK_VERSION:-r26d}"
NDK_DIR="$ROOT_DIR/android-ndk-$NDK_VERSION"
LOG_FILE="$OUTPUT_DIR/build-v27.log"

export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "=== $* ==="; }
trap 'rc=$?; echo "[V27] Échec ligne ${LINENO}, code ${rc}. Log: ${LOG_FILE}" >&2; exit "$rc"' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

note "V27 — BakaSU + SUSFS pour kiev"
date -u '+UTC %Y-%m-%d %H:%M:%S'
df -h
[[ "$ROOT_DIR" != "/" && -n "$ROOT_DIR" ]] || die "ROOT_DIR invalide."

note "Dépendances"
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex git curl wget unzip zip \
  libelf-dev libssl-dev libncurses-dev device-tree-compiler cpio python3 python3-pip \
  gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld file
python3 -m pip install --user --upgrade gdown
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

note "Clonage du kernel"
rm -rf "$KERNEL_DIR"
git clone --depth=1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR"
cd "$KERNEL_DIR"
git log -1 --format='Kernel commit: %H%nKernel subject: %s'
[[ -f "arch/arm64/configs/$DEFCONFIG" ]] || die "Defconfig absent: arch/arm64/configs/$DEFCONFIG"
[[ -f kernel/reboot.c && -f kernel/sys.c && -f fs/read_write.c ]] || die "Fichiers kernel requis absents."

note "Intégration BakaSU sync-susfs"
curl --fail --location --retry 3 --retry-delay 2 "$BAKASU_SETUP_URL" -o "$WORK_DIR/bakasu-setup.sh"
bash "$WORK_DIR/bakasu-setup.sh" sync-susfs
if [[ -d drivers/kernelsu ]]; then
  KSU_DIR=drivers/kernelsu
elif [[ -d KernelSU/kernel ]]; then
  KSU_DIR=KernelSU/kernel
elif [[ -d KernelSU ]]; then
  KSU_DIR=KernelSU
else
  die "Le setup BakaSU n'a créé aucun répertoire KernelSU connu."
fi
echo "KSU_DIR=$KSU_DIR"
git status --short | head -80 || true

# Never turn Makefile $(error ...) checks into warnings: they protect against
# incompatible combinations and must be fixed explicitly instead.
grep -Rqs --include='*.c' --include='*.h' 'ksu_handle_setresuid' "$KSU_DIR" || die "ksu_handle_setresuid absent de BakaSU."
grep -Rqs --include='*.c' --include='*.h' 'ksu_handle_sys_reboot' "$KSU_DIR" || die "ksu_handle_sys_reboot absent de BakaSU."

note "Patch SUSFS 4.19 contrôlé"
PATCH_REPO_DIR="$WORK_DIR/susfs-patch-repo"
rm -rf "$PATCH_REPO_DIR"
git clone --depth=1 --branch "$SUSFS_PATCH_REF" "$SUSFS_PATCH_REPO" "$PATCH_REPO_DIR"
git -C "$PATCH_REPO_DIR" log -1 --format='Patch repo commit: %H%nPatch repo subject: %s'
if [[ -n "${SUSFS_PATCH_RELATIVE_PATH:-}" ]]; then
  PATCH_FILE="$PATCH_REPO_DIR/$SUSFS_PATCH_RELATIVE_PATH"
  [[ -f "$PATCH_FILE" ]] || die "SUSFS_PATCH_RELATIVE_PATH introuvable: $PATCH_FILE"
else
  mapfile -t PATCH_CANDIDATES < <(find "$PATCH_REPO_DIR/Patches" -type f -name '*4.19*.patch' 2>/dev/null | sort)
  [[ "${#PATCH_CANDIDATES[@]}" -gt 0 ]] || die "Aucun patch SUSFS 4.19 trouvé dans le dépôt cyberc3dr."
  COMPATIBLE_PATCHES=()
  for candidate in "${PATCH_CANDIDATES[@]}"; do
    if patch --batch --forward --dry-run -p1 < "$candidate" >/dev/null 2>&1; then
      COMPATIBLE_PATCHES+=("$candidate")
    fi
  done
  if [[ "${#COMPATIBLE_PATCHES[@]}" -ne 1 ]]; then
    printf 'Patchs 4.19 trouvés (%s), applicables (%s):\n' "${#PATCH_CANDIDATES[@]}" "${#COMPATIBLE_PATCHES[@]}"
    printf '  candidat: %s\n' "${PATCH_CANDIDATES[@]}"
    printf '  applicable: %s\n' "${COMPATIBLE_PATCHES[@]:-aucun}"
    die "Le patch compatible n'est pas unique. Définis SUSFS_PATCH_RELATIVE_PATH après vérification."
  fi
  PATCH_FILE="${COMPATIBLE_PATCHES[0]}"
fi
echo "Patch sélectionné: ${PATCH_FILE#"$PATCH_REPO_DIR"/}"
patch --batch --forward --dry-run -p1 < "$PATCH_FILE" || die "Le patch SUSFS ne s'applique pas proprement; aucun .rej supprimé."
patch --batch --forward -p1 < "$PATCH_FILE"

note "Includes SUSFS ciblés"
python3 - "$KSU_DIR" <<'PY'
from pathlib import Path
import re, sys
ksu_dir = Path(sys.argv[1])
header = Path('include/linux/susfs_def.h')
if header.exists():
    header_name = 'linux/susfs_def.h'
else:
    found = list(ksu_dir.rglob('susfs_def.h'))
    if not found:
        raise SystemExit('ERROR: susfs_def.h absent après le patch SUSFS.')
    header_name = str(found[0].relative_to(Path('.')))
for path in map(Path, ['fs/proc/task_mmu.c', 'fs/namespace.c', 'fs/super.c', 'fs/stat.c']):
    if not path.exists():
        continue
    text = path.read_text(errors='replace')
    if 'susfs_def.h' in text or not re.search(r'\bSUSFS_[A-Z0-9_]+\b', text):
        continue
    includes = list(re.finditer(r'^#include\s+[<"].*[>"]\s*$', text, re.M))
    if not includes:
        raise SystemExit(f'ERROR: emplacement include introuvable dans {path}')
    pos = includes[-1].end()
    text = text[:pos] + f'\n#include <{header_name}>' + text[pos:]
    path.write_text(text)
    print(f'Include SUSFS ajouté: {path}')
PY

note "Configuration kernel"
mkdir -p out
make O=out "$DEFCONFIG"
python3 - <<'PY'
from pathlib import Path
import re
cfg = Path('out/.config')
text = cfg.read_text()
required = {
    'CONFIG_KSU': 'y',
    'CONFIG_KSU_MANUAL_HOOK': 'y',
    'CONFIG_KSU_SUSFS': 'y',
    'CONFIG_SECCOMP': 'y',
    'CONFIG_SECCOMP_FILTER': 'y',
    'CONFIG_COMPAT': 'y',
    'CONFIG_COMPAT_32BIT_TIME': 'y',
}
for key, value in required.items():
    text = re.sub(rf'^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$', '', text, flags=re.M)
    text += f'{key}={value}\n'
auto_key = 'CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK'
text = re.sub(rf'^(?:{re.escape(auto_key)}=.*|# {re.escape(auto_key)} is not set)$', '', text, flags=re.M)
text += f'# {auto_key} is not set\n'
cfg.write_text(text)
PY
make O=out olddefconfig
for required in CONFIG_KSU CONFIG_KSU_MANUAL_HOOK CONFIG_KSU_SUSFS CONFIG_SECCOMP CONFIG_SECCOMP_FILTER; do
  grep -qx "${required}=y" out/.config || die "$required=y absent après olddefconfig."
done
if grep -qx 'CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y' out/.config; then
  die 'CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK reste activé; le hook setresuid manuel pourrait être neutralisé.'
fi
grep -E '^(CONFIG_KSU=|CONFIG_KSU_MANUAL_HOOK=|CONFIG_KSU_SUSFS=|CONFIG_KSU_SUSFS_[A-Z0-9_]+=|CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=|CONFIG_COMPAT=|CONFIG_KPROBES=)' out/.config | sort

note "Hooks manuels pour le kernel 4.19"
python3 - "$KSU_DIR" <<'PY'
from pathlib import Path
import re, sys
ksu_dir = Path(sys.argv[1])
def has_symbol(symbol):
    for p in ksu_dir.rglob('*'):
        if p.is_file() and p.suffix in {'.c', '.h'}:
            try:
                if re.search(r'\b' + re.escape(symbol) + r'\s*\(', p.read_text(errors='ignore')):
                    return True
            except OSError:
                pass
    return False
def has_token(token):
    for p in ksu_dir.rglob('*'):
        if p.is_file() and p.suffix in {'.c', '.h'}:
            try:
                if re.search(r'\b' + re.escape(token) + r'\b', p.read_text(errors='ignore')):
                    return True
            except OSError:
                pass
    return False

# Linux 4.19 manual-hook integration: the setresuid hook is needed for the
# setuid_hook.c path that calls disable_seccomp() on kernels older than 5.10.
sys_c = Path('kernel/sys.c')
text = sys_c.read_text()
if not re.search(r'\(void\)\s*ksu_handle_setresuid\s*\(\s*ruid\s*,\s*euid\s*,\s*suid\s*\)', text):
    if not has_symbol('ksu_handle_setresuid'):
        raise SystemExit('ERROR: handler ksu_handle_setresuid absent.')
    anchor = 'long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)'
    if anchor not in text:
        raise SystemExit('ERROR: __sys_setresuid() absent; hook non injecté.')
    if 'extern int ksu_handle_setresuid' not in text:
        decl = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n'
        text = text.replace(anchor, decl + '\n' + anchor, 1)
    body = re.search(r'long __sys_setresuid\(uid_t ruid, uid_t euid, uid_t suid\)\s*\{', text)
    if not body:
        raise SystemExit('ERROR: corps de __sys_setresuid() introuvable.')
    call = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n'
    text = text[:body.end()] + call + text[body.end():]
    sys_c.write_text(text)
    print('Hook setresuid ajouté.')
else:
    print('Hook setresuid déjà présent dans kernel/sys.c.')

# Keep the reboot hook in normal syscall context (not in a kprobe handler).
reboot_c = Path('kernel/reboot.c')
text = reboot_c.read_text()
if not re.search(r'ksu_handle_sys_reboot\s*\(\s*magic1\s*,\s*magic2\s*,\s*cmd\s*,\s*&arg\s*\)', text):
    anchor = 'SYSCALL_DEFINE4(reboot,'
    if anchor not in text:
        raise SystemExit('ERROR: SYSCALL_DEFINE4(reboot, ...) absent.')
    if 'extern int ksu_handle_sys_reboot' not in text:
        decl = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\n'
        text = text.replace(anchor, decl + '\n' + anchor, 1)
    fn = re.search(r'SYSCALL_DEFINE4\(reboot,[\s\S]*?\)\s*\{', text)
    if not fn:
        raise SystemExit('ERROR: corps du syscall reboot introuvable.')
    tail = text[fn.end():]
    ret = re.search(r'\bint ret\s*=\s*0\s*;', tail)
    if not ret:
        raise SystemExit("ERROR: 'int ret = 0;' absent dans reboot syscall.")
    pos = fn.end() + ret.end()
    call = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n'
    text = text[:pos] + call + text[pos:]
    reboot_c.write_text(text)
    print('Hook reboot ajouté.')
else:
    print('Hook reboot déjà présent.')

# Add init.rc read hook only if this BakaSU branch exports both symbols.
rw = Path('fs/read_write.c')
text = rw.read_text()
if 'ksu_handle_sys_read' not in text and has_symbol('ksu_handle_sys_read') and has_token('ksu_init_rc_hook'):
    decl = ('\n#ifdef CONFIG_KSU_MANUAL_HOOK\n'
            'extern bool ksu_init_rc_hook __read_mostly;\n'
            'extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n'
            '#endif\n')
    anchor = 'SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)'
    if anchor not in text:
        raise SystemExit('ERROR: signature read() attendue absente de fs/read_write.c.')
    text = text.replace(anchor, decl + '\n' + anchor, 1)
    body = re.search(r'SYSCALL_DEFINE3\(read,\s*unsigned int,\s*fd,\s*char __user \*,\s*buf,\s*size_t,\s*count\)\s*\{', text)
    if not body:
        raise SystemExit('ERROR: corps read() introuvable.')
    call = '\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif\n'
    text = text[:body.end()] + call + text[body.end():]
    rw.write_text(text)
    print('Hook read/init.rc ajouté.')
elif 'ksu_handle_sys_read' in text:
    print('Hook read déjà présent.')
else:
    print('Hook read non ajouté : symboles non exposés par cette révision BakaSU.')

if 'ksu_handle_setresuid' not in sys_c.read_text():
    raise SystemExit('ERROR: vérification hook setresuid échouée.')
if 'ksu_handle_sys_reboot' not in reboot_c.read_text():
    raise SystemExit('ERROR: vérification hook reboot échouée.')
PY

note "Patchs Motorola"
# Keep the module version check enabled by default. Opt-in only if the user
# explicitly wants the old V26 behavior after understanding the trade-off.
if [[ "${DISABLE_MODULE_VERSION_CHECK:-0}" == "1" ]]; then
  grep -q 'if (!check_version(' kernel/module.c || die "Motif check_version absent."
  sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
  echo "AVERTISSEMENT: vérification de version des modules neutralisée par option explicite."
else
  echo "Vérification de version des modules conservée."
fi

# Preserve the Motorola compatibility fixes from V26, but add each stub only
# when the source tree has no implementation. This avoids duplicate symbols.
python3 <<'PYMOTO'
from pathlib import Path
import re
root = Path('.')
target = Path('techpack/display/msm/msm_drv.c')
if not target.exists():
    print('msm_drv.c absent; tactile compatibility stubs skipped.')
else:
    files = [p for p in root.rglob('*.c') if 'out' not in p.parts and p != target]
    contents = []
    for p in files:
        try: contents.append(p.read_text(errors='ignore'))
        except OSError: pass
    all_other = '\n'.join(contents)
    missing_panel_register = not re.search(r'\bpanel_register_notifier\s*\([^;]*\)\s*\{', all_other, re.S)
    missing_panel_unregister = not re.search(r'\bpanel_unregister_notifier\s*\([^;]*\)\s*\{', all_other, re.S)
    missing_touch = not re.search(r'\btouch_set_state\s*\([^;]*\)\s*\{', all_other, re.S)
    text = target.read_text(errors='replace')
    additions = []
    if missing_panel_register or missing_panel_unregister:
        if 'motorola_panel_notifier_list' not in text:
            additions.extend(['#include <linux/notifier.h>', 'static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);'])
        if missing_panel_register:
            additions.extend([
                'int panel_register_notifier(struct notifier_block *nb)',
                '{ return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb); }',
                'EXPORT_SYMBOL(panel_register_notifier);'])
        if missing_panel_unregister:
            additions.extend([
                'int panel_unregister_notifier(struct notifier_block *nb)',
                '{ return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb); }',
                'EXPORT_SYMBOL(panel_unregister_notifier);'])
    if missing_touch:
        additions.extend(['void touch_set_state(int state) { (void)state; }', 'EXPORT_SYMBOL(touch_set_state);'])
    if additions:
        if '#include <linux/module.h>' not in text:
            text = '#include <linux/module.h>\n' + text
        text += '\n/* V27 Motorola compatibility stubs; added only for missing definitions. */\n' + '\n'.join(additions) + '\n'
        target.write_text(text)
        print('Stubs Motorola manquants ajoutés: ' + ', '.join(
            name for name, missing in [('panel_register_notifier', missing_panel_register),
                                       ('panel_unregister_notifier', missing_panel_unregister),
                                       ('touch_set_state', missing_touch)] if missing))
    else:
        print('Implémentations tactiles existantes; aucun stub ajouté.')
PYMOTO

note "Compilation kernel"
make O=out -j"$JOBS" Image 2>&1 | tee "$OUTPUT_DIR/kernel-build-v27.log"
KERNEL_IMAGE="$KERNEL_DIR/out/arch/arm64/boot/Image"
[[ -s "$KERNEL_IMAGE" ]] || die "Image compilée absente."
sha256sum "$KERNEL_IMAGE" | awk '{print $1}' > "$WORK_DIR/kernel.sha256"
echo "Kernel SHA256: $(cat "$WORK_DIR/kernel.sha256")"
file "$KERNEL_IMAGE"
ls -lh "$KERNEL_IMAGE"

note "Compilation ksud Android arm64"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 --fail --location https://sh.rustup.rs -o "$WORK_DIR/rustup-init.sh"
  sh "$WORK_DIR/rustup-init.sh" -y
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
rustup toolchain install nightly --profile minimal
rustup target add aarch64-linux-android --toolchain nightly
if [[ ! -d "$NDK_DIR" ]]; then
  NDK_ZIP="$WORK_DIR/android-ndk-$NDK_VERSION-linux.zip"
  curl --fail --location --retry 3 "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip" -o "$NDK_ZIP"
  unzip -q "$NDK_ZIP" -d "$ROOT_DIR"
fi
[[ -x "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang" ]] || die "Clang Android NDK introuvable."
export ANDROID_NDK_ROOT="$NDK_DIR" ANDROID_NDK_HOME="$NDK_DIR"
export AARCH64_CLANG_PATH="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
KSUD_SRC="$ROOT_DIR/ksud-src"
rm -rf "$KSUD_SRC"
git clone --depth=1 --branch sync-susfs https://github.com/Baka-SU/BakaSU.git "$KSUD_SRC"
git -C "$KSUD_SRC" log -1 --format='BakaSU userspace commit: %H%nBakaSU userspace subject: %s'
KSUD_DIR="$KSUD_SRC/userspace/ksud"
[[ -d "$KSUD_DIR" ]] || die "userspace/ksud absent."
mkdir -p "$KSUD_DIR/.cargo"
cat > "$KSUD_DIR/.cargo/config.toml" <<CARGO
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"

[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
CARGO
export CARGO_NET_GIT_FETCH_WITH_CLI=true
(cd "$KSUD_DIR" && cargo +nightly build --release --target aarch64-linux-android)
KSUD_BINARY="$KSUD_DIR/target/aarch64-linux-android/release/ksud"
[[ -s "$KSUD_BINARY" ]] || die "Binaire ksud absent à l'emplacement attendu."
file "$KSUD_BINARY"
cp "$KSUD_BINARY" "$ROOT_DIR/ksud"
chmod 0755 "$ROOT_DIR/ksud"

note "Téléchargement/validation boot stock"
python3 -m gdown "https://drive.google.com/uc?id=$BOOT_GDRIVE_ID" -O "$WORK_DIR/boot-stock.img"
[[ -s "$WORK_DIR/boot-stock.img" ]] || die "boot-stock.img absent ou vide."
BOOT_SIZE="$(stat -c%s "$WORK_DIR/boot-stock.img")"
(( BOOT_SIZE >= 50000000 )) || die "boot-stock.img invalide (${BOOT_SIZE} octets); vérifie BOOT_GDRIVE_ID."
if [[ -n "$DTBO_GDRIVE_ID" ]]; then
  if ! python3 -m gdown "https://drive.google.com/uc?id=$DTBO_GDRIVE_ID" -O "$WORK_DIR/dtbo-stock.img"; then
    echo "AVERTISSEMENT: DTBO non téléchargé; artefact DTBO omis."
    rm -f "$WORK_DIR/dtbo-stock.img"
  fi
fi

note "Préparation magiskboot"
MAGISK_APK="$WORK_DIR/Magisk-v27.0.apk"
curl --fail --location --retry 3 https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -o "$MAGISK_APK"
mkdir -p "$REPACK_DIR"
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$REPACK_DIR/magiskboot"
chmod 0755 "$REPACK_DIR/magiskboot"
cp "$WORK_DIR/boot-stock.img" "$REPACK_DIR/boot.img"

note "Repack boot.img"
cd "$REPACK_DIR"
./magiskboot unpack boot.img
[[ -s ramdisk.cpio ]] || die "magiskboot n'a pas produit ramdisk.cpio."
cp "$KERNEL_IMAGE" kernel
./magiskboot cpio ramdisk.cpio \
  'mkdir 0755 data' \
  'mkdir 0755 data/adb' \
  'mkdir 0755 data/adb/ksud' \
  "add 0755 data/adb/ksud/ksud $ROOT_DIR/ksud"
cp "$ROOT_DIR/ksud" local_su_binary
chmod 0755 local_su_binary
./magiskboot cpio ramdisk.cpio \
  'mkdir 0755 system' \
  'mkdir 0755 system/bin' \
  'add 06755 system/bin/su local_su_binary'
rm -f local_su_binary
./magiskboot repack boot.img "$WORK_DIR/final-boot.img"
[[ -s "$WORK_DIR/final-boot.img" ]] || die "Repack boot échoué."

note "Vérification de l'image finale"
VERIFY_DIR="$WORK_DIR/verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
cp "$WORK_DIR/final-boot.img" "$VERIFY_DIR/verify-boot.img"
(
  cd "$VERIFY_DIR"
  "$REPACK_DIR/magiskboot" unpack verify-boot.img
  [[ -s kernel ]] || die "Kernel absent de l'image repackée."
  [[ "$(sha256sum kernel | awk '{print $1}')" == "$(cat "$WORK_DIR/kernel.sha256")" ]] || die "Hash du kernel extrait différent du kernel compilé."
  "$REPACK_DIR/magiskboot" cpio ramdisk.cpio 'exists data/adb/ksud/ksud' >/dev/null
  "$REPACK_DIR/magiskboot" cpio ramdisk.cpio 'exists system/bin/su' >/dev/null
)
echo "Vérification OK: kernel identique et ksud/su présents dans le ramdisk."

note "Artefacts"
cp "$WORK_DIR/final-boot.img" "$OUTPUT_DIR/BakaSU-SUSFS-v27-kiev-boot.img"
[[ ! -s "$WORK_DIR/dtbo-stock.img" ]] || cp "$WORK_DIR/dtbo-stock.img" "$OUTPUT_DIR/dtbo.img"
cp "$KERNEL_IMAGE" "$OUTPUT_DIR/Image"
cp "$ROOT_DIR/ksud" "$OUTPUT_DIR/ksud"
cp "$WORK_DIR/kernel.sha256" "$OUTPUT_DIR/kernel.sha256"
{
  echo "kernel_repo=$KERNEL_REPO"
  echo "kernel_ref=$KERNEL_REF"
  echo "kernel_commit=$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  echo "bakasu_setup_url=$BAKASU_SETUP_URL"
  echo "susfs_patch_repo=$SUSFS_PATCH_REPO"
  echo "susfs_patch_ref=$SUSFS_PATCH_REF"
  echo "kernel_sha256=$(cat "$WORK_DIR/kernel.sha256")"
  echo "boot_source_gdrive_id=$BOOT_GDRIVE_ID"
} > "$OUTPUT_DIR/build-manifest-v27.txt"
echo
echo '=== BUILD V27 TERMINÉ ==='
ls -lh "$OUTPUT_DIR"
