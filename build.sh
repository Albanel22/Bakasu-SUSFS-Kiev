#!/bin/bash
################################################################################
# Build ReSukiSU + SUSFS pour LineageOS 23.2 (SM8250 - Motorola One 5G Ace)
# PRODUCTION-GRADE - Gestion d'erreurs stricte
################################################################################

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-.}"
readonly OUTPUT_DIR="${BUILD_DIR}/output"
readonly LOGS_DIR="${OUTPUT_DIR}/logs"
readonly TEMP_DIR="${BUILD_DIR}/.tmp"
readonly LOG_FILE="${LOGS_DIR}/build.log"

# Device & Kernel
readonly DEVICE_NAME="kiev"
readonly DEVICE_SOC="SM8250"
readonly KERNEL_VERSION="4.19.325"
readonly KERNEL_BRANCH="lineage-23.2"
readonly KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
readonly KERNEL_CONFIG="vendor/lito-perf_defconfig"

# Google Drive IDs
readonly BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
readonly DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

# URLs
readonly RESUKISU_SETUP_URL="https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh"
readonly MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk"

# Compilation
readonly PARALLEL_JOBS="${PARALLEL_JOBS:=$(nproc)}"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Timestamps
readonly BUILD_START=$(date +%s)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

setup_logging() {
    mkdir -p "${LOGS_DIR}" || die "Impossible de créer ${LOGS_DIR}"
    
    {
        echo "================================================================================"
        echo "Build: LineageOS 23.2 + ReSukiSU + SUSFS"
        echo "Device: ${DEVICE_NAME} (${DEVICE_SOC})"
        echo "Kernel: ${KERNEL_VERSION}"
        echo "Date: $(date)"
        echo "================================================================================"
    } > "${LOG_FILE}" || die "Impossible d'écrire dans ${LOG_FILE}"
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -w "${LOG_FILE}" ]; then
        echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo "[${ts}] [${level}] ${msg}"
    fi
}

log_info()    { log_msg "INFO" "$@"; }
log_warn()    { log_msg "WARN" "$@"; }
log_error()   { log_msg "ERROR" "$@"; }
log_success() { log_msg "✓" "$@"; }

print_section() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║ $*"
    echo "╚════════════════════════════════════════════════════════════════╝"
    log_info "=== $* ==="
}

elapsed_time() {
    local end=$(date +%s)
    local duration=$((end - BUILD_START))
    printf "%02d:%02d:%02d" $((duration/3600)) $((duration%3600/60)) $((duration%60))
}

cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Build échoué (code: $exit_code)"
        log_error "Temps écoulé: $(elapsed_time)"
        log_error "Log complet: ${LOG_FILE}"
    fi
    exit $exit_code
}

trap cleanup_on_error EXIT

# =============================================================================
# PRÉ-VÉRIFICATIONS
# =============================================================================

init_build() {
    print_section "Initialisation"
    
    mkdir -p "${OUTPUT_DIR}" "${LOGS_DIR}" "${TEMP_DIR}" || \
        die "Impossible de créer les répertoires"
    
    setup_logging
    
    log_info "BUILD_DIR: ${BUILD_DIR}"
    log_info "OUTPUT_DIR: ${OUTPUT_DIR}"
    log_info "PARALLEL_JOBS: ${PARALLEL_JOBS}"
    
    return 0
}

check_space() {
    local available=$(df "${BUILD_DIR}" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [ -z "$available" ] || [ "$available" -lt 20971520 ]; then
        log_warn "Espace disque < 20GB disponible"
    else
        log_info "Espace disque: $(numfmt --to=iec-i --suffix=B $((available * 1024)) 2>/dev/null || echo "${available}KB")"
    fi
}

verify_tools() {
    print_section "Vérification des outils requis"
    
    # TOOLS_TO_CHECK: maps "command" to "package_name"
    local -A tools_map=(
        ["git"]="git"
        ["curl"]="curl"
        ["wget"]="wget"
        ["python3"]="python3"
        ["make"]="make"
        ["unzip"]="unzip"
        ["zip"]="zip"
        ["clang"]="clang"
        ["lld"]="lld"
        ["aarch64-linux-gnu-gcc"]="gcc-aarch64-linux-gnu"
        ["arm-linux-gnueabi-gcc"]="gcc-arm-linux-gnueabi"
    )
    
    local missing=()
    
    for cmd in "${!tools_map[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            log_success "$cmd"
        else
            missing+=("${tools_map[$cmd]}")
            log_warn "✗ $cmd (${tools_map[$cmd]})"
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Outils manquants: ${missing[*]}"
        return 1
    fi
    
    return 0
}

install_deps() {
    print_section "Installation des dépendances"
    
    if [ -z "${CI:-}" ] && [ -z "${GITHUB_WORKSPACE:-}" ]; then
        log_warn "Pas en CI, installation manuelle requise"
        log_warn "Exécutez: sudo apt-get install build-essential clang lld llvm device-tree-compiler"
        return 0
    fi
    
    log_info "Nettoyage APT..."
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
    sudo apt-get clean -qq 2>/dev/null || true
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    
    log_info "Mise à jour APT..."
    sudo apt-get update -qq 2>&1 | grep -E "Hit|Get" | head -20 || true
    
    log_info "Installation groupe 1: Build essentials..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        bc bison build-essential ccache flex \
        glibc-source libelf-dev libssl-dev libncurses-dev || die "Groupe 1 échoué"
    
    log_info "Installation groupe 2: Cross-compilers..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi || die "Groupe 2 échoué"
    
    log_info "Installation groupe 3: LLVM/Clang..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        clang llvm lld llvm-tools device-tree-compiler || die "Groupe 3 échoué"
    
    log_info "Installation groupe 4: Outils..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        zip unzip curl git python3 python3-pip mkbootimg || die "Groupe 4 échoué"
    
    log_info "Installation de gdown..."
    pip3 install --quiet --user gdown 2>/dev/null || \
        log_warn "gdown optionnel (non critique)"
    
    log_success "Dépendances installées"
    
    # Vérifier post-install
    log_info "Vérification post-installation..."
    if ! verify_tools; then
        die "Certains outils manquent toujours après installation"
    fi
    
    return 0
}

# =============================================================================
# KERNEL BUILD
# =============================================================================

clone_kernel() {
    print_section "Clone du kernel"
    
    local kernel_dir="${BUILD_DIR}/kernel_sources"
    
    if [ -d "${kernel_dir}/.git" ]; then
        log_warn "Kernel déjà cloné"
        cd "${kernel_dir}"
    else
        log_info "Clone depuis: ${KERNEL_REPO}"
        git clone \
            --depth=1 \
            -b "${KERNEL_BRANCH}" \
            "${KERNEL_REPO}" \
            "${kernel_dir}" 2>&1 | tee -a "${LOG_FILE}" || \
            die "Clone échoué"
        cd "${kernel_dir}"
    fi
    
    local commit=$(git log --oneline -1)
    log_success "Kernel: $commit"
}

integrate_resukisu() {
    print_section "Intégration ReSukiSU"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true
    
    log_info "Exécution setup.sh..."
    curl -fsSL "${RESUKISU_SETUP_URL}" | bash 2>&1 | tee -a "${LOG_FILE}" || \
        die "ReSukiSU setup échoué"
    
    # Vérifier Kconfig
    if ! grep -q 'source.*[Kk]ernelsu.*Kconfig' drivers/Kconfig 2>/dev/null; then
        die "Kconfig ReSukiSU non intégré"
    fi
    
    # Vérifier Makefile
    if ! grep -q 'CONFIG_KSU' drivers/Makefile 2>/dev/null; then
        die "Makefile ReSukiSU non intégré"
    fi
    
    log_success "ReSukiSU intégré"
}

apply_hooks() {
    print_section "Application des hooks manuels"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    # Hook: execveat
    if ! grep -q "ksu_handle_execveat" fs/exec.c 2>/dev/null; then
        log_info "Hook execveat..."
        python3 << 'EOF_HOOK1'
import re, sys
with open('fs/exec.c', 'r') as f:
    content = f.read()
if 'ksu_execveat_hook' in content:
    sys.exit(0)
extern = '#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n                void *argv, void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n                 void *argv, void *envp, int *flags);\n#endif\n'
m = re.search(r'(#include.*?\n)+', content)
if m:
    content = content[:m.end()] + extern + content[m.end():]
old = '\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);'
new = old + '\n\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_execveat_hook))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n\telse\n\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n#endif'
content = content.replace(old, new, 1)
with open('fs/exec.c', 'w') as f:
    f.write(content)
print('OK')
EOF_HOOK1
        [ $? -ne 0 ] && die "Hook execveat échoué"
    fi
    
    # Hook: setresuid
    if ! grep -q "ksu_handle_setresuid" kernel/sys.c 2>/dev/null; then
        log_info "Hook setresuid..."
        python3 << 'EOF_HOOK2'
import re, sys
with open('kernel/sys.c', 'r') as f:
    content = f.read()
if 'ksu_handle_setresuid' in content:
    sys.exit(0)
extern = '#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n#endif\n'
m = re.search(r'(#include.*?\n)+', content)
if m:
    content = content[:m.end()] + extern + content[m.end():]
hook = '#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif\n'
for marker in ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']:
    if marker in content:
        content = content.replace(marker, marker + '\n' + hook, 1)
        break
with open('kernel/sys.c', 'w') as f:
    f.write(content)
print('OK')
EOF_HOOK2
        [ $? -ne 0 ] && die "Hook setresuid échoué"
    fi
    
    # Hook: sys_read
    if ! grep -q "ksu_handle_sys_read" fs/read_write.c 2>/dev/null; then
        log_info "Hook sys_read..."
        python3 << 'EOF_HOOK3'
import sys
with open('fs/read_write.c', 'r') as f:
    content = f.read()
if 'ksu_handle_sys_read' in content:
    sys.exit(0)
extern = '#ifdef CONFIG_KSU\nextern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n'
import re
m = re.search(r'(#include.*?\n)+', content)
if m:
    content = content[:m.end()] + extern + content[m.end():]
old = 'SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{'
new = old + '\n#ifdef CONFIG_KSU\n\tksu_handle_sys_read(fd, &buf, &count);\n#endif'
content = content.replace(old, new, 1)
with open('fs/read_write.c', 'w') as f:
    f.write(content)
print('OK')
EOF_HOOK3
        [ $? -ne 0 ] && die "Hook sys_read échoué"
    fi
    
    # Hook: input_event
    if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c 2>/dev/null; then
        log_info "Hook input_event..."
        python3 << 'EOF_HOOK4'
import re, sys
with open('drivers/input/input.c', 'r') as f:
    content = f.read()
if 'ksu_handle_input_handle_event' in content:
    sys.exit(0)
extern = '#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern __attribute__((cold)) int ksu_handle_input_handle_event(\n\t\t\tunsigned int *type, unsigned int *code, int *value);\n#endif\n'
m = re.search(r'(#include.*?\n)+', content)
if m:
    content = content[:m.end()] + extern + content[m.end():]
old = 'if (is_event_supported(type, dev->evbit, EV_MAX)) {'
new = '#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\n\tif (is_event_supported(type, dev->evbit, EV_MAX)) {'
content = content.replace(old, new, 1)
with open('drivers/input/input.c', 'w') as f:
    f.write(content)
print('OK')
EOF_HOOK4
        [ $? -ne 0 ] && die "Hook input_event échoué"
    fi
    
    log_success "Tous les hooks appliqués"
}

verify_hooks() {
    print_section "Vérification des hooks"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    local checks=(
        "ksu_handle_execveat:fs/exec.c"
        "ksu_handle_setresuid:kernel/sys.c"
        "ksu_handle_sys_read:fs/read_write.c"
        "ksu_handle_input_handle_event:drivers/input/input.c"
    )
    
    for check in "${checks[@]}"; do
        local fn="${check%%:*}"
        local file="${check##*:}"
        
        if grep -q "$fn" "$file" 2>/dev/null; then
            log_success "✓ $fn"
        else
            die "Hook manquant: $fn dans $file"
        fi
    done
}

configure_kernel() {
    print_section "Configuration du kernel"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    if [ ! -f "arch/arm64/configs/${KERNEL_CONFIG}" ]; then
        die "Config ${KERNEL_CONFIG} introuvable"
    fi
    
    mkdir -p out
    
    log_info "Chargement config..."
    make O=out LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        "${KERNEL_CONFIG}" 2>&1 | tee -a "${LOG_FILE}" || \
        die "make defconfig échoué"
    
    log_info "Ajout options KSU/SUSFS..."
    cat >> out/.config << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
# CONFIG_KPROBES is not set
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
EOF
    
    make O=out LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        olddefconfig 2>&1 | tee -a "${LOG_FILE}" || \
        die "olddefconfig échoué"
    
    # Forcer les options
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config || true
    sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config || true
    
    log_success "Configuration complète"
}

compile_kernel() {
    print_section "Compilation du kernel"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    log_info "Compilation (${PARALLEL_JOBS} jobs)..."
    
    if ! make O=out LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        -j"${PARALLEL_JOBS}" \
        Image 2>&1 | tee -a "${LOG_FILE}"; then
        
        log_error "Compilation échouée"
        die "Kernel compilation failed"
    fi
    
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        die "Image kernel non générée"
    fi
    
    local size=$(du -h out/arch/arm64/boot/Image | cut -f1)
    log_success "Kernel compilé: ${size}"
}

# =============================================================================
# OUTPUT
# =============================================================================

collect_artifacts() {
    print_section "Collecte des artefacts"
    
    mkdir -p "${OUTPUT_DIR}"
    
    if [ -f "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" ]; then
        cp "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" \
            "${OUTPUT_DIR}/kernel-Image" || die "Copie kernel échouée"
        log_success "✓ kernel-Image ($(du -h "${OUTPUT_DIR}/kernel-Image" | cut -f1))"
    fi
    
    if [ -f "${LOG_FILE}" ]; then
        log_success "✓ build.log"
    fi
    
    log_info ""
    log_info "Fichiers générés:"
    ls -lh "${OUTPUT_DIR}/"
}

print_summary() {
    local duration=$(elapsed_time)
    
    print_section "BUILD RÉUSSI!"
    
    log_success "Temps total: ${duration}"
    log_info "Device: ${DEVICE_NAME} (${DEVICE_SOC})"
    log_info "Kernel: ${KERNEL_VERSION}"
    log_info "Output: ${OUTPUT_DIR}"
    log_info "Log: ${LOG_FILE}"
    
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    init_build
    check_space
    
    if ! verify_tools; then
        log_warn "Outils manquants, installation..."
        install_deps || die "Installation dépendances échouée"
    else
        log_success "Tous les outils présents"
    fi
    
    clone_kernel
    integrate_resukisu
    apply_hooks
    verify_hooks
    configure_kernel
    compile_kernel
    
    collect_artifacts
    print_summary
}

main "$@"
