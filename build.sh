#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-ALBANEL-V4 : Static exports SELinux + hooks doc officielle
# Source : Albanel22/ReSukiSU (fork intact d'août 2026, v4.2.0-rc1)
# Mode : MANUAL_HOOK seul (SUSFS désactivé)
# =============================================================================

echo "=== Build ReSukiSU (Albanel22) + Static exports SELinux ==="
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

# ==================== 1. CLONAGE DU KERNEL ====================
echo "=== Clonage du kernel LineageOS ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU (Albanel22) ====================
echo "=== Intégration ReSukiSU (Albanel22) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

git clone --depth=1 https://github.com/Albanel22/ReSukiSU.git KernelSU
if [ ! -d "KernelSU/kernel" ]; then
    echo "❌ KernelSU/kernel introuvable après clone"
    exit 1
fi
echo "✅ ReSukiSU (Albanel22) cloné"

DRIVER_DIR="drivers"
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$(pwd)/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"

if ! grep -q "kernelsu" "$DRIVER_DIR/Makefile"; then
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_DIR/Makefile"
fi
if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"; then
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"
fi

KSU_DIR="KernelSU"
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 2b. NETTOYAGE UNICODE ====================
echo ""
echo "=== Nettoyage Unicode robuste de KernelSU ==="

python3 << 'PYEOF'
import os
from pathlib import Path

UNICODE_SPACES = [
    '\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F',
    '\u205F', '\u3000',
]

count_files = 0
count_fixes = 0

for root, dirs, files in os.walk('KernelSU'):
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content:
                        content = content.replace(uchar, ' ')
                        count_fixes += 1
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count_files += 1
            except Exception as e:
                print(f"  ⚠️  Erreur sur {filepath}: {e}")

print(f"✅ {count_files} fichiers nettoyés, {count_fixes} remplacements effectués")
PYEOF

echo ""
echo "=== Vérification post-nettoyage ==="
UNICODE_REMAINING=$(grep -rlP '[\x{00A0}\x{2000}-\x{200B}\x{202F}\x{205F}\x{3000}]' "$KSU_DIR" --include="*.c" --include="*.h" 2>/dev/null || true)
if [ -n "$UNICODE_REMAINING" ]; then
    echo "  ⚠️  Unicode restant dans :"
    echo "$UNICODE_REMAINING" | head -5
else
    echo "  ✅ Aucun Unicode restant détecté"
fi

# ==================== 3. STATIC EXPORTS SELINUX ====================
echo ""
echo "=== Static exports SELinux (doc officielle ReSukiSU) ==="

# Export 1 : write_op
if [ -f "security/selinux/selinuxfs.c" ]; then
    if grep -q "^static ssize_t (\*write_op\[\])" security/selinux/selinuxfs.c; then
        sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
        echo "  ✅ write_op exporté"
    elif grep -q "^static ssize_t (\*write_op\[\])(struct file \*, char \*, size_t)" security/selinux/selinuxfs.c; then
        sed -i 's/^static ssize_t (\*write_op\[\])(struct file \*, char \*, size_t)/ssize_t (*write_op[])(struct file *, char *, size_t)/' security/selinux/selinuxfs.c
        echo "  ✅ write_op exporté (variante)"
    else
        echo "  ⚠️  write_op non trouvé ou déjà exporté"
    fi
fi

# Export 2 : sel_handle_status_ops
if [ -f "security/selinux/selinuxfs.c" ]; then
    if grep -q "^static const struct file_operations sel_handle_status_ops" security/selinux/selinuxfs.c; then
        sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
        echo "  ✅ sel_handle_status_ops exporté"
    else
        echo "  ⚠️  sel_handle_status_ops non trouvé ou déjà exporté"
    fi
fi

# Export 3 : selinux_status_page + selinux_status_lock (4.17-)
if [ -f "security/selinux/ss/status.c" ]; then
    if grep -q "^static struct page \*selinux_status_page" security/selinux/ss/status.c; then
        sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
        echo "  ✅ selinux_status_page exporté"
    fi
    if grep -q "^static DEFINE_MUTEX(selinux_status_lock)" security/selinux/ss/status.c; then
        sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
        echo "  ✅ selinux_status_lock exporté"
    fi
fi

# Export 4 : policy_rwlock (4.17-)
if [ -f "security/selinux/ss/services.c" ]; then
    if grep -q "^static DEFINE_RWLOCK(policy_rwlock)" security/selinux/ss/services.c; then
        sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
        echo "  ✅ policy_rwlock exporté"
    fi
fi

# Export 5 : sel_mutex (4.17-)
if [ -f "security/selinux/selinuxfs.c" ]; then
    if grep -q "^static DEFINE_MUTEX(sel_mutex)" security/selinux/selinuxfs.c; then
        sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
        echo "  ✅ sel_mutex exporté"
    fi
fi

# Export 6 : selinux_ops (4.2-)
if [ -f "security/selinux/hooks.c" ]; then
    if grep -q "^static struct security_operations selinux_ops" security/selinux/hooks.c; then
        sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
        echo "  ✅ selinux_ops exporté"
    fi
fi

# Export 7 : security_dump_masked_av + context_struct_compute_av (6.6+)
if [ -f "security/selinux/ss/services.c" ]; then
    if grep -q "^static void security_dump_masked_av" security/selinux/ss/services.c; then
        sed -i 's/^static void security_dump_masked_av/void security_dump_masked_av/' security/selinux/ss/services.c
        echo "  ✅ security_dump_masked_av exporté"
    fi
    if grep -q "^static void context_struct_compute_av" security/selinux/ss/services.c; then
        sed -i 's/^static void context_struct_compute_av/void context_struct_compute_av/' security/selinux/ss/services.c
        echo "  ✅ context_struct_compute_av exporté"
    fi
fi

echo "✅ Static exports SELinux terminés"

# ==================== 4. HOOKS MANUELS (doc officielle) ====================
echo ""
echo "=== Hooks manuels (patterns doc officielle ReSukiSU) ==="

# --- Hook 1 : execveat (fs/exec.c) ---
if ! grep -q "ksu_handle_execveat(" fs/exec.c; then
  cat > /tmp/h_execveat.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat(&' not in content and 'ksu_handle_execveat((' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_execveat' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);'''
    new = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &flags);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: execveat")
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_execveat.py
fi

# --- Hook 2 : faccessat (fs/open.c) ---
if ! grep -q "ksu_handle_faccessat(" fs/open.c; then
  cat > /tmp/h_faccessat.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat(&dfd' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_faccessat' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
    new = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: faccessat")
with open('fs/open.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_faccessat.py
fi

# --- Hooks 3,4,5 : stat (fs/stat.c) ---
if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/h_stat.py << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f: content = f.read()

if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

if 'ksu_handle_stat(&dfd' not in content:
    old = '\terror = vfs_fstatat(dfd, filename, &stat, flag);'
    new = '''#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: stat")
    else:
        old2 = '\treturn vfs_fstatat(dfd, filename, &stat, flag);'
        new2 = '''#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
        if old2 in content:
            content = content.replace(old2, new2, 1)
            print("OK: stat (fallback)")

if 'ksu_handle_newfstat_ret' not in content:
    old = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: newfstat_ret")

if 'ksu_handle_fstat64_ret' not in content:
    old = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: fstat64_ret")

with open('fs/stat.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_stat.py
fi

# --- Hook 6 : sys_reboot ---
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  cat > /tmp/h_reboot.py << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_sys_reboot' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''	char buffer[256];
	int ret = 0;'''
    new = '''	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: sys_reboot")
with open('kernel/reboot.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_reboot.py
fi

# --- Hook 7 : setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/h_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f: content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_setresuid' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    for marker in ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']:
        if marker in content:
            new_code = marker + '''
#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
            content = content.replace(marker, new_code, 1)
            print("OK: setresuid")
            break
with open('kernel/sys.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_setresuid.py
fi

# --- Hook 8 : sys_read (géré par AUTO_INITRC_HOOK, mais on l'ajoute en sécurité) ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/h_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_init_rc_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd,
				char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern bool ksu_init_rc_hook' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''	return ksys_read(fd, buf, count);'''
    new = '''#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_init_rc_hook))
		ksu_handle_sys_read(fd, &buf, &count);
#endif
	return ksys_read(fd, buf, count);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: sys_read")
with open('fs/read_write.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_read.py
fi

# --- Hook 9 : input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/h_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f: content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern bool ksu_input_hook' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU_MANUAL_HOOK
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: input_event")
with open('drivers/input/input.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_input.py
fi

# ==================== 5. CONFIGURATION ====================
echo ""
echo "=== Configuration (MANUAL_HOOK seul, SUSFS désactivé) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "# CONFIG_KSU_SUSFS is not set"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

# ==================== 5b. FORÇAGE MANUAL_HOOK POST-OLDDEFCONFIG ====================
echo ""
echo "=== Forçage de CONFIG_KSU_MANUAL_HOOK après olddefconfig ==="

if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi

for opt in KSU_MANUAL_HOOK_AUTO_SETUID_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
    if grep -q "# CONFIG_${opt} is not set" out/.config; then
        sed -i "s/# CONFIG_${opt} is not set/CONFIG_${opt}=y/" out/.config
    fi
    if ! grep -q "^CONFIG_${opt}=y" out/.config; then
        echo "CONFIG_${opt}=y" >> out/.config
    fi
done

if grep -q "# CONFIG_KPROBES is not set" out/.config; then
    sed -i 's/# CONFIG_KPROBES is not set/CONFIG_KPROBES=y/' out/.config
fi

if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    sed -i 's/^CONFIG_KSU_SUSFS=y/# CONFIG_KSU_SUSFS is not set/' out/.config
fi

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo ""
echo "=== VÉRIFICATION FINALE DE LA CONFIG ==="
FAIL=0
for opt in KSU_MANUAL_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK KPROBES; do
    if grep -q "^CONFIG_${opt}=y" out/.config; then
        echo "  ✅ CONFIG_${opt}=y"
    else
        echo "  ❌ CONFIG_${opt} NON ACTIF"
        FAIL=1
    fi
done
if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    echo "  ⚠️  CONFIG_KSU_SUSFS=y (devrait être désactivé)"
    FAIL=1
else
    echo "  ✅ CONFIG_KSU_SUSFS désactivé"
fi

if [ "$FAIL" -eq 1 ]; then
    echo ""
    echo "❌ ERREUR : La config n'a pas été correctement appliquée."
    exit 1
fi
echo "✅ Configuration validée : MANUAL_HOOK + AUTO_* + KPROBES (sans SUSFS)"

# ==================== 6. PATCH SIGNATURES + TACTILE ====================
echo ""
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patches Motorola appliqués"

# ==================== 7. COMPILATION ====================
echo ""
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 8. REPACK ====================
echo ""
echo "=== Repack avec Google Drive ==="
cd "$GITHUB_WORKSPACE"

echo "→ Téléchargement boot.img..."
rm -f boot-stock.img
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi

echo "→ Téléchargement dtbo.img..."
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
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. DIAGNOSTIC POST-REPACK ====================
echo ""
echo "=== DIAGNOSTIC POST-REPACK ==="
mkdir -p verify
cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    if [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ]; then
        echo "✅ Noyau extrait IDENTIQUE au noyau compilé"
    fi
    for sym in "kernelsu" "KERNEL_SU_RC" "ksu_ksud_init"; do
        if strings kernel 2>/dev/null | grep -q "$sym"; then
            echo "  ✅ '$sym' trouvé"
        else
            echo "  ❌ '$sym' ABSENT"
        fi
    done
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/ReSukiSU-Albanel-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ (test-albanel-v4) ==="
echo "Source : Albanel22/ReSukiSU"
echo "Mode : MANUAL_HOOK seul (SUSFS désactivé)"
echo "Static exports SELinux : activés"
echo "Nettoyage Unicode : activé"
ls -lh output/
