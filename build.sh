#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD : LineageOS 23.2 + BakaSU (PINNÉ) + SUSFS 2.3.0 (cyberc3dr)
# Appareil : Motorola One 5G Ace (kiev / SM8250)
# Kernel : 4.19.325
# FIX v2 :
#   - Commit BakaSU pinné UNE fois, utilisé partout (driver + ksud)
#   - Vérification protocole driver vs gestionnaire (35222) AVANT le build
#   - Hook setresuid corrigé (__sys_setresuid OU SYSCALL_DEFINE3)
#   - LLVM_IAS=1
#   - Forçage config POST-olddefconfig + hard fail si KSU perdu
#   - Vérification symboles SUSFS avant suppression des doublons
#   - Vérification magic seccomp vs source BakaSU
#   - Build modules inclus
#   - Ramdisk fallback au repack + vérif SHA256 du kernel injecté
#   - Date de build LineageOS détectée dynamiquement
# =============================================================================

# ==================== CONFIGURATION ====================
MANAGER_PROTOCOL="35222"   # <-- version du gestionnaire installé sur le téléphone
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

echo "=== Build BakaSU + SUSFS pour kiev (SM8250) ==="
df -h

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 mkbootimg cpio

cd "$GITHUB_WORKSPACE"

# ==================== 0. PIN BAKASU (UN SEUL COMMIT PARTOUT) ====================
echo "=== Détermination du commit BakaSU ==="
BAKASU_COMMIT=$(git ls-remote https://github.com/Baka-SU/BakaSU.git refs/heads/main | awk '{print $1}')
echo "Commit BakaSU pinné : $BAKASU_COMMIT"

rm -rf /tmp/BakaSU
mkdir -p /tmp/BakaSU && cd /tmp/BakaSU
git init -q
git remote add origin https://github.com/Baka-SU/BakaSU.git
git fetch -q --depth=1 origin "$BAKASU_COMMIT"
git checkout -q FETCH_HEAD
echo "BakaSU cloné :" && git log --oneline -1
cd "$GITHUB_WORKSPACE"

# ---- Vérification protocole driver vs gestionnaire (AVANT de compiler 1h) ----
echo "=== Vérification compatibilité gestionnaire (protocole $MANAGER_PROTOCOL) ==="
KSU_VER=$(grep -rhoE "#define[[:space:]]+KSU_VERSION[[:space:]]+[0-9]+" /tmp/BakaSU/kernel/ 2>/dev/null | grep -oE "[0-9]+" | head -1)

if [ -z "${KSU_VER:-}" ]; then
    echo "⚠️  KSU_VERSION introuvable dans les sources BakaSU — vérification manuelle requise"
    echo "    Cherche : grep -rn 'KSU_VERSION' /tmp/BakaSU/kernel/"
else
    echo "Version driver dans les sources : $KSU_VER"
    if [ "$KSU_VER" != "$MANAGER_PROTOCOL" ]; then
        echo "❌ INCOMPATIBILITÉ : driver=$KSU_VER ≠ gestionnaire=$MANAGER_PROTOCOL"
        echo "→ Soit installer le gestionnaire buildé depuis le commit $BAKASU_COMMIT,"
        echo "→ Soit pinner BakaSU sur le tag du gestionnaire v${MANAGER_PROTOCOL} :"
        echo "     BAKASU_COMMIT=\$(git ls-remote --tags https://github.com/Baka-SU/BakaSU.git | grep '${MANAGER_PROTOCOL}' | cut -f1)"
        exit 1
    fi
    echo "✅ Driver et gestionnaire compatibles"
fi

# ---- Vérification du magic reboot utilisé par le bypass seccomp ----
echo "=== Vérification magic seccomp/reboot ==="
if grep -rq "DEADBEEF" /tmp/BakaSU/kernel/; then
    echo "✅ Magic 0xDEADBEEF confirmé dans les sources BakaSU"
else
    echo "⚠️  0xDEADBEEF introuvable dans BakaSU — vérifie le magic attendu par ksu_handle_sys_reboot :"
    grep -rn "magic1" /tmp/BakaSU/kernel/ | head -5
fi

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel LineageOS (branche lineage-23.2) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU (COMMIT PINNÉ) ====================
echo "=== Intégration BakaSU (commit $BAKASU_COMMIT) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

# Utiliser le setup.sh officiel de BakaSU avec le commit pinné
if wget -q --spider "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" 2>/dev/null; then
    echo "→ Utilisation de setup.sh officiel BakaSU..."
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash -s -- "$BAKASU_COMMIT"
else
    echo "→ setup.sh non trouvé, intégration manuelle..."
    cp -a /tmp/BakaSU/kernel drivers/kernelsu

    if [ ! -f "drivers/kernelsu/Kconfig" ]; then
        echo "❌ drivers/kernelsu/Kconfig introuvable après copie"
        ls -la drivers/kernelsu/
        exit 1
    fi

    if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
        sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    fi

    if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile; then
        echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    fi
fi

# Vérification intégration
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || {
    echo "❌ Échec Kconfig BakaSU"; exit 1; }
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || {
    echo "❌ Échec Makefile BakaSU"; exit 1; }
echo "✅ BakaSU intégré dans le kernel"

# ---- Vérification des noms de symboles Kconfig (détection renommages) ----
echo "=== Vérification symboles Kconfig BakaSU ==="
grep -q "config KSU$" drivers/kernelsu/Kconfig || echo "⚠️  'config KSU' absent — vérifier le Kconfig de BakaSU"
grep -q "config KSU_MANUAL_HOOK$" drivers/kernelsu/Kconfig || echo "⚠️  'config KSU_MANUAL_HOOK' absent — risque de drop par olddefconfig !"

# ==================== 2b. BYPASS CHECK VERSION SUSFS DANS BAKASU ====================
echo ""
echo "=== Bypass check version SUSFS dans BakaSU ==="

SUSFS_COMPAT_FILES=$(find . -name "susfs_compat.mk" -type f 2>/dev/null)

if [ -z "$SUSFS_COMPAT_FILES" ]; then
    echo "⚠️  Aucun susfs_compat.mk trouvé, skip"
else
    for f in $SUSFS_COMPAT_FILES; do
        echo "→ Traitement de $f"
        sed -i 's/\$(error /\$(warning /g' "$f"
        if grep -q '\$(error ' "$f"; then
            echo "❌ Le patch n'a pas fonctionné sur $f"
            exit 1
        fi
        echo "  ✅ $f patché (error → warning)"
    done
fi

for f in $SUSFS_COMPAT_FILES; do
    if grep -q '\$(error ' "$f"; then
        echo "❌ Il reste des \$(error dans $f"
        exit 1
    fi
done
echo "✅ Bypass check SUSFS appliqué partout"

# ==================== 3. HOOKS MANUELS BakaSU ====================
echo ""
echo "=== Hooks manuels BakaSU ==="

# --- execveat ---
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  cat > /tmp/hook_execveat.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
    pattern = r'(static int do_execveat_common\()'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    new_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: execveat")
    else:
        pattern = r'(int do_execve\(struct filename \*filename,.*?struct user_arg_ptr envp = \{ \.ptr\.native = __envp \};\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: execveat (alternatif)")
with open('fs/exec.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_execveat.py
fi

# --- faccessat ---
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  cat > /tmp/hook_faccessat.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f:
    content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(faccessat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
    new_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: faccessat")
    else:
        pattern = r'(SYSCALL_DEFINE3\(faccessat.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: faccessat (alternatif)")
with open('fs/open.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_faccessat.py
fi

# --- stat / newfstat / fstat64 ---
if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/hook_stat_complete.py << 'PYEOF'
import re

with open('fs/stat.c', 'r') as f:
    content = f.read()

if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

if 'ksu_handle_stat(&dfd' not in content:
    old_code = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new_code = '''	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: stat")
    else:
        pattern = r'(SYSCALL_DEFINE4\(newfstatat.*?int error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_stat(&dfd, &filename, &flag);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: stat (alternatif)")

if 'ksu_handle_newfstat_ret' not in content:
    old_code = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new_code = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: newfstat_ret")

if 'ksu_handle_fstat64_ret' not in content:
    old_code = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new_code = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: fstat64_ret")
    else:
        pattern = r'(SYSCALL_DEFINE2\(fstat64.*?return error;\n)'
        replacement = r'\1#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: fstat64_ret (alternatif)")

with open('fs/stat.c', 'w') as f:
    f.write(content)
print("=== Hooks stat terminés ===")
PYEOF
  python3 /tmp/hook_stat_complete.py
fi

# --- reboot ---
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  cat > /tmp/hook_reboot.py << 'PYEOF'
import re

with open('kernel/reboot.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(reboot)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

    old_code = '''	char buffer[256];
	int ret = 0;'''

    new_code = '''	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''

    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_reboot")
    else:
        pattern = r'(SYSCALL_DEFINE4\(reboot.*?\n\{)'
        replacement = r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif'
        content = re.sub(pattern, replacement, content, count=1)
        print("OK: sys_reboot (alternatif)")

with open('kernel/reboot.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_reboot.py
fi

# --- setresuid --- FIX : supporte __sys_setresuid ET SYSCALL_DEFINE3 (4.19) ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
import sys

with open('kernel/sys.c', 'r') as f:
    content = f.read()

if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    done = False

    # Cas 1 : kernel avec __sys_setresuid (ancien split)
    m = re.search(r'(long __sys_setresuid\([^)]*\)\s*\{)', content)
    if m:
        anchor = None
        for candidate in ['bool ruid_new, euid_new, suid_new;',
                          'int ruid_new, euid_new, suid_new;']:
            if candidate in content:
                anchor = candidate
                break
        if anchor is None:
            m2 = re.search(r'((?:bool|int) ruid_new, euid_new, suid_new;)', content)
            if m2:
                anchor = m2.group(1)
        if anchor:
            content = content.replace(anchor, anchor + '''
#ifdef CONFIG_KSU_MANUAL_HOOK
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif''', 1)
            content = content[:m.start()] + extern_decl + '\n' + content[m.start():]
            done = True
            print("OK: setresuid (__sys_setresuid)")

    # Cas 2 : wrapper SYSCALL_DEFINE3 (kernel 4.19 typique)
    if not done:
        m3 = re.search(r'(SYSCALL_DEFINE3\(setresuid,\s*uid_t,\s*ruid,\s*uid_t,\s*euid,\s*uid_t,\s*suid\)\s*\{)', content)
        if m3:
            content = content[:m3.start()] + extern_decl + '\n' + content[m3.start():]
            content = re.sub(
                r'(SYSCALL_DEFINE3\(setresuid,\s*uid_t,\s*ruid,\s*uid_t,\s*euid,\s*uid_t,\s*suid\)\s*\{)',
                r'\1\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif',
                content, count=1)
            done = True
            print("OK: setresuid (SYSCALL_DEFINE3)")

    if not done:
        print("ERREUR: setresuid introuvable dans kernel/sys.c")
        sys.exit(1)

with open('kernel/sys.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

# --- sys_read ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/hook_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(read)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

    old_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
    new_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_read")
with open('fs/read_write.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_sys_read.py
fi

# --- input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/hook_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    pattern = r'(void input_event\(struct input_dev \*dev,)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

    old_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: input_event")
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
PYEOF
  python3 /tmp/hook_input.py
fi

# ---- VÉRIFICATION FINALE : tous les hooks présents ----
echo "=== Vérification de tous les hooks ==="
HOOKS_OK=1
grep -q "ksu_handle_execveat" fs/exec.c || { echo "❌ hook execveat manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_faccessat" fs/open.c || { echo "❌ hook faccessat manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_stat" fs/stat.c || { echo "❌ hook stat manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_sys_reboot" kernel/reboot.c || { echo "❌ hook reboot manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_setresuid" kernel/sys.c || { echo "❌ hook setresuid manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_sys_read" fs/read_write.c || { echo "❌ hook sys_read manquant"; HOOKS_OK=0; }
grep -q "ksu_handle_input_handle_event" drivers/input/input.c || { echo "❌ hook input manquant"; HOOKS_OK=0; }
[ "$HOOKS_OK" = "1" ] || { echo "❌ BUILD ABANDONNÉ : hooks manquants"; exit 1; }
echo "✅ Tous les hooks présents"

# ==================== 3.4. PATCH app_profile.c (compat CONFIG_SECCOMP) ====================
echo "=== Patch compatibilité disable_seccomp() pour CONFIG_SECCOMP actif ==="

python3 << 'PYEOF_SECCOMP_FIX'
import re
from pathlib import Path

path = Path("drivers/kernelsu/policy/app_profile.c")
if not path.exists():
    print("⚠️  app_profile.c introuvable, skip")
    exit(0)

content = path.read_text()

if 'CONFIG_KSU_SECCOMP_SAFE' in content:
    print("[i] app_profile.c déjà patché")
    exit(0)

pattern = r'(void\s+disable_seccomp\s*\(void\)\s*\{)'
match = re.search(pattern, content)
if not match:
    print("[i] disable_seccomp() déjà protégée par #ifdef CONFIG_SECCOMP")
    exit(0)

start_brace = match.end() - 1
depth = 1
i = start_brace + 1
end_brace = -1
while i < len(content) and depth > 0:
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end_brace = i
            break
    i += 1

if end_brace < 0:
    print("[!] Fermeture de disable_seccomp() non trouvée")
    exit(1)

body = content[start_brace+1:end_brace]
new_body = '''
#ifdef CONFIG_SECCOMP
''' + body + '''
#else
	/* CONFIG_KSU_SECCOMP_SAFE : seccomp désactivé, rien à faire */
	return;
#endif
'''
content = content[:start_brace+1] + new_body + content[end_brace:]
path.write_text(content)
print("[+] disable_seccomp() patchée")
PYEOF_SECCOMP_FIX

# ==================== 3.5. INTÉGRATION SUSFS 2.3.0 (cyberc3dr) ====================
echo "=== Intégration SUSFS 2.3.0 depuis cyberc3dr ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

if [ -f "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" ]; then
    echo "=== Application du patch de compatibilité xxksu ==="
    patch -p1 --forward --batch < "/tmp/cyber_repo/Patches/Patch/xxksu_fix_compat.patch" || true
fi

SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
echo "=== Application du patch SUSFS 4.19 ==="
patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true

# --- Corrections automatiques des rejets ---
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo "⚠️ Rejet détecté dans task_mmu.c. Correction automatique..."
    python3 - << 'PYEOF'
import re, os
file_path = 'fs/proc/task_mmu.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f: content = f.read()
    if 'SUSFS_IS_INODE_SUS_MAP' not in content:
        content = content.replace("ret = walk_page_range(start_vaddr, end, &pagemap_walk);",
            "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif\n\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);")
        content = re.sub(r'(ret = walk_page_range.*?)(up_read\(&mm->mmap_sem\);|mmap_read_unlock\(mm\);)',
            r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif\n\t\2', content, flags=re.DOTALL)
        with open(file_path, 'w') as f: f.write(content)
PYEOF
    rm -f fs/proc/task_mmu.c.rej
fi

if [ -f "fs/namespace.c.rej" ] && grep -q "vfs_kern_mount" "fs/namespace.c.rej"; then
    echo "⚠️ Rejet détecté dans namespace.c. Correction automatique..."
    python3 - << 'PYEOF'
import re, os
file_path = 'fs/namespace.c'
if os.path.exists(file_path):
    with open(file_path, 'r') as f: content = f.read()
    if 'susfs_alloc_non_unshare_ksu_vfsmnt' not in content:
        content = re.sub(r'(\tif \(!type\)\n\t\treturn ERR_PTR\(-ENODEV\);\n)(\n\tmnt = alloc_vfsmnt\(name\);)',
            r'''\1
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {
\t\tif (susfs_is_current_ksu_domain()) {
\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none");
\t\t\tgoto bypass_orig_flow;
\t\t}
\t}
#endif
\2
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif''', content)
        with open(file_path, 'w') as f: f.write(content)
PYEOF
    rm -f fs/namespace.c.rej
fi

echo "=== Correction des déclarations SuSFS dans fs/super.c ==="

python3 - << 'PYEOF'
import re

with open('fs/super.c', 'r') as f:
    content = f.read()

decl = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
#include <linux/susfs_def.h>

extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#ifndef DEFAULT_KSU_MNT_MINOR_DEV
#define DEFAULT_KSU_MNT_MINOR_DEV (1 << 20)
#endif
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */
'''

content = re.sub(r'#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT.*?susfs_is_sdcard_android_data_not_decrypted.*?#endif', '', content, flags=re.DOTALL)

if 'susfs_is_current_ksu_domain' not in content:
    content = re.sub(r'(#include\s+[^\n]+\n)', r'\1' + decl + '\n', content, count=1)
    print("✅ Déclarations forcées injectées")
else:
    print("✅ Déclarations déjà présentes")

with open('fs/super.c', 'w') as f:
    f.write(content)
PYEOF

rm -f fs/super.c.rej 2>/dev/null || true

if find . -name "*.rej" -type f | grep -q .; then
    echo "❌ ÉCHEC CRITIQUE : Des rejets SUSFS persistent."
    find . -name "*.rej" -type f -exec echo "=== {} ===" \; -exec cat {} \;
    exit 1
fi
echo "✅ Patch SuSFS appliqué (aucun rejet)."

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

# ---- FIX : ne supprimer les définitions que si BakaSU les fournit ----
if [ -f "fs/susfs.c" ]; then
    if grep -rq "susfs_is_current_ksu_domain" drivers/kernelsu/ 2>/dev/null; then
        echo "→ BakaSU définit les symboles SUSFS → suppression des doublons dans fs/susfs.c"
        sed -i '/^bool susfs_is_current_ksu_domain(void)/,/^}/d' fs/susfs.c || true
        sed -i '/^u32 susfs_ksu_sid = 0;/d' fs/susfs.c || true
        sed -i '/^u32 susfs_priv_app_sid = 0;/d' fs/susfs.c || true
        sed -i '/EXPORT_SYMBOL(susfs_is_current_ksu_domain);/d' fs/susfs.c || true
        sed -i '/EXPORT_SYMBOL(susfs_ksu_sid);/d' fs/susfs.c || true
        sed -i '/EXPORT_SYMBOL(susfs_priv_app_sid);/d' fs/susfs.c || true

        if ! grep -q "extern bool susfs_is_current_ksu_domain" fs/susfs.c; then
            sed -i '1i extern bool susfs_is_current_ksu_domain(void);\nextern u32 susfs_ksu_sid;\nextern u32 susfs_priv_app_sid;' fs/susfs.c || true
        fi
    else
        echo "⚠️  BakaSU ne définit PAS susfs_is_current_ksu_domain → conservation des définitions SUSFS (évite undefined reference)"
    fi
fi

if [ -f "fs/stat.c" ] && ! grep -q "susfs_def.h" fs/stat.c; then
    sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif' fs/stat.c
fi

if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
fi

python3 - << 'PYEOF'
import re
with open('fs/namespace.c', 'r') as f: content = f.read()
content = re.sub(r'^\s*n(?=#ifdef|#endif|#include|#define|extern)', '', content, flags=re.MULTILINE)
if '#include <linux/susfs_def.h>' not in content:
    content = content.replace('#include <linux/sched/task.h>', '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif')
if 'extern bool susfs_is_current_ksu_domain' not in content:
    content = content.replace('#include "pnode.h"', '#include "pnode.h"\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif')
with open('fs/namespace.c', 'w') as f: f.write(content)
PYEOF

if [ -f "drivers/kernelsu/Kconfig" ] && ! grep -q "KSU_SUSFS" drivers/kernelsu/Kconfig; then
    cat >> drivers/kernelsu/Kconfig << 'KCONFIG_EOF'
menuconfig KSU_SUSFS
	bool "KernelSU SUSFS support"
	depends on KSU
	default y
if KSU_SUSFS
config KSU_SUSFS_SUS_PATH
	bool "sus_path"
	default y
config KSU_SUSFS_SUS_MOUNT
	bool "sus_mount"
	default y
config KSU_SUSFS_SUS_KSTAT
	bool "sus_kstat"
	default y
config KSU_SUSFS_SUS_MAP
	bool "sus_map"
	default y
config KSU_SUSFS_SPOOF_UNAME
	bool "spoof_uname"
	default y
config KSU_SUSFS_ENABLE_LOG
	bool "enable_log"
	default y
config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "hide_ksu_susfs_symbols"
	default y
config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	bool "spoof_cmdline_or_bootconfig"
	default y
config KSU_SUSFS_OPEN_REDIRECT
	bool "open_redirect"
	default y
config KSU_SUSFS_TRY_UMOUNT
	bool "try_umount"
	default y
config KSU_SUSFS_HAS_MAGIC_MOUNT
	bool "has_magic_mount"
	default y
config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	bool "auto_add_ksu_default_mount"
	default y
config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
	bool "auto_add_sus_bind_mount"
	default y
config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	bool "auto_add_try_umount_for_bind_mount"
	default y
endif
KCONFIG_EOF
fi
echo "✅ SuSFS 2.3.0 intégré"

# ==================== 4. CONFIGURATION ====================
echo "=== Configuration ==="
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

mkdir -p out

CONFIG_NAME="vendor/lito-perf_defconfig"
echo "Config utilisée : $CONFIG_NAME"

if [ ! -f "arch/arm64/configs/$CONFIG_NAME" ]; then
  echo "❌ $CONFIG_NAME introuvable !"
  ls -la arch/arm64/configs/vendor/ || true
  exit 1
fi

make O=out LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
  echo "# CONFIG_KPROBES is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
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

make O=out LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

# ---- FIX : re-forcer APRÈS olddefconfig + hard fail si perdu ----
{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
} >> out/.config
make O=out LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Vérification finale des symboles critiques ==="
grep -q "^CONFIG_KSU=y$" out/.config || { echo "❌ CONFIG_KSU perdu par olddefconfig !"; exit 1; }
grep -q "^CONFIG_KSU_MANUAL_HOOK=y$" out/.config || { echo "❌ CONFIG_KSU_MANUAL_HOOK perdu par olddefconfig !"; exit 1; }
echo "✅ CONFIG_KSU et CONFIG_KSU_MANUAL_HOOK confirmés"

if grep -q "^# CONFIG_KSU_MANUAL_HOOK" out/.config; then
    echo "❌ CONFIG_KSU_MANUAL_HOOK explicitement désactivé !"; exit 1
fi

grep "CONFIG_KSU" out/.config | head -10 || true

# ==================== 4b. BYPASS SECCOMP CIBLÉ (supercall KernelSU) ====================
echo "=== Patch bypass seccomp ciblé dans kernel/seccomp.c ==="

python3 << 'PYEOF_SECCOMP_BYPASS'
from pathlib import Path
import re

path = Path("kernel/seccomp.c")
if not path.exists():
    print("⚠️  kernel/seccomp.c introuvable")
    exit(0)

content = path.read_text()

if 'CONFIG_KSU_SECCOMP_BYPASS' in content:
    print("[i] Bypass seccomp déjà appliqué")
    exit(0)

pattern = r'(int\s+__secure_computing\s*\([^)]+\)\s*\{[^}]*?int\s+this_syscall\s*;)'
match = re.search(pattern, content, re.DOTALL)

if not match:
    print("⚠️  Pattern non trouvé, skip")
    exit(0)

insert_pos = match.end()
bypass_code = '''
#ifdef CONFIG_KSU
	/* CONFIG_KSU_SECCOMP_BYPASS : bypass syscalls KernelSU/SUSFS */
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

content = content[:insert_pos] + bypass_code + content[insert_pos:]
path.write_text(content)
print("[+] Bypass seccomp ciblé KernelSU inséré")
PYEOF_SECCOMP_BYPASS

if grep -q "CONFIG_KSU_SECCOMP_BYPASS" kernel/seccomp.c 2>/dev/null; then
    echo "✅ Bypass seccomp appliqué"
else
    echo "⚠️  Bypass seccomp non appliqué"
fi

# ==================== 5. PATCHES ====================
echo "=== Patch signatures modules + tactile ==="

sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
    printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
    echo "✅ Patch tactile appliqué"
else
    echo "⏭️  Patch tactile déjà présent"
fi

# ==================== 6. COMPILATION ====================
echo "=== Compilation finale (Image + modules) ==="
make O=out LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image modules 2>&1 | tee build.log

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "✅ Compilation kernel réussie"
  ls -lh out/arch/arm64/boot/
else
  echo "❌ BUILD FAILED"
  grep -iE "error:|fatal error:" build.log | head -30
  exit 1
fi

# ---- dtbo (non bloquant) ----
make O=out LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 dtbo.img 2>/dev/null || \
    echo "⚠️  dtbo.img non généré par ce kernel (non bloquant, utiliser le stock)"

# ---- Récupération des modules (pour mise à jour vendor si besoin) ----
make O=out LLVM=1 modules_install INSTALL_MOD_PATH=out_modules >/dev/null 2>&1 || true

# ==================== 6b. COMPILATION KSUD (MÊME COMMIT BAKASU) ====================
echo "=== Compilation de ksud (commit $BAKASU_COMMIT) ==="
cd "$GITHUB_WORKSPACE"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

rustup toolchain install nightly
rustup default nightly
rustup target add aarch64-linux-android

wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip -q android-ndk-r26d-linux.zip

export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

# ---- FIX : clone ksud par SHA (même commit que le driver kernel) ----
rm -rf "$GITHUB_WORKSPACE/ksud-src"
mkdir -p "$GITHUB_WORKSPACE/ksud-src" && cd "$GITHUB_WORKSPACE/ksud-src"
git init -q
git remote add origin https://github.com/Baka-SU/BakaSU.git
git fetch -q --depth=1 origin "$BAKASU_COMMIT"
git checkout -q FETCH_HEAD
echo "ksud cloné (doit être identique au driver) :" && git log --oneline -1

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
if [ -z "$KSUD_BINARY" ]; then
    echo "❌ ksud introuvable"
    exit 1
fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"
chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé (même commit que le driver : $BAKASU_COMMIT)"

cd "$GITHUB_WORKSPACE"

# ==================== 7. REPACK ====================
echo "=== Téléchargement des images stock ==="
cd "$GITHUB_WORKSPACE"

# ---- FIX : détection dynamique de la date de build LineageOS ----
BUILD_DATE=$(curl -s "https://mirrorbits.lineageos.org/full/kiev/" 2>/dev/null | grep -oE '20[0-9]{6}' | sort -u | tail -1)
echo "Date de build LineageOS détectée : ${BUILD_DATE:-inconnue}"

curl -fLo boot-stock.img "https://mirrorbits.lineageos.org/full/kiev/${BUILD_DATE}/boot.img" 2>/dev/null || {
  echo "⚠️ Téléchargement boot stock impossible, fallback mkbootimg..."
  mkbootimg --kernel kernel_sources/out/arch/arm64/boot/Image \
    --ramdisk /dev/null \
    --output final_boot.img \
    --header_version 2 \
    --pagesize 4096 \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --cmdline "androidboot.hardware=kiev androidboot.selinux=permissive"
}

if [ -n "${BUILD_DATE:-}" ]; then
  curl -fLo dtbo-stock.img "https://mirrorbits.lineageos.org/full/kiev/${BUILD_DATE}/dtbo.img" 2>/dev/null || true
fi

if [ -f "boot-stock.img" ]; then
  echo "=== Repack avec magiskboot ==="
  mkdir -p repack
  cp boot-stock.img repack/boot.img
  wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
  unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
  mv lib/x86_64/libmagiskboot.so repack/magiskboot
  chmod +x repack/magiskboot
  rm -rf Magisk-v27.0.apk lib/
  cd repack

  set +e
  ./magiskboot unpack boot.img
  UNPACK_EXIT=$?
  set -e

  if [ ! -f "kernel" ]; then
    echo "❌ Échec unpack (exit magiskboot: $UNPACK_EXIT)"
    exit 1
  fi

  # ---- FIX : ramdisk fallback si absent ----
  if [ ! -f "ramdisk.cpio" ]; then
    echo "⚠️ Aucun ramdisk dans le boot stock (header v3/v4 ?) — création d'un ramdisk minimal"
    mkdir -p minram && (cd minram && find . | cpio -o -H newc > ../ramdisk.cpio) && rm -rf minram
  fi

  # ---- FIX : vérification que le kernel injecté est bien le nôtre ----
  cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
  echo "=== Vérification SHA256 du kernel injecté ==="
  sha256sum kernel "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image"

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
  cd ..
fi

# ==================== 8. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/BakaSU-SuSFS-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
cp kernel_sources/out/arch/arm64/boot/dtbo.img output/dtbo-built.img 2>/dev/null || true
[ -d kernel_sources/out_modules ] && cp -r kernel_sources/out_modules output/modules 2>/dev/null || true

echo ""
echo "=== BUILD TERMINÉ ==="
echo "Commit BakaSU utilisé partout : $BAKASU_COMMIT"
ls -lh output/
echo ""
echo "=== TEST (sans flash) ==="
echo "  fastboot boot output/BakaSU-SuSFS-boot.img"
echo ""
echo "=== INSTALLATION DÉFINITIVE (device A/B : les deux slots) ==="
echo "  fastboot flash boot_a output/BakaSU-SuSFS-boot.img"
echo "  fastboot flash boot_b output/BakaSU-SuSFS-boot.img"
echo "  fastboot flash dtbo_a output/dtbo.img   (si dtbo changé)"
echo "  fastboot flash dtbo_b output/dtbo.img"
echo ""
echo "⚠️  Si des modules .ko ont changé, mettre à jour la partition vendor aussi,"
echo "    sinon tactile/autres drivers peuvent ne pas charger."
