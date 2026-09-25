#!/usr/bin/env bash
# uninstall.sh — remove o driver Bluetooth RT3290 (rtbth) do hp-lnx
#
# Uso:  sudo ./uninstall.sh
#
# IMPORTANTE: a remoção do módulo em runtime tem risco documentado de kernel
# panic com o rtbth em kernels >= 4.4. Por isso este script NÃO faz rmmod.
# Ele só limpa a instalação e pede que você reinicie. Se o Bluetooth parar de
# funcionar antes do reboot, é isso: o módulo ainda está carregado, o estado
# morre no próximo boot.

set -euo pipefail

DKMS_PKG="rtbth"
DKMS_VER="3.9.6"
DKMS_SRC="/usr/src/${DKMS_PKG}-${DKMS_VER}"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s %s\n' "$Y" "$N" "$*"; }

[ "$(id -u)" -eq 0 ] || { printf 'rode como root: sudo ./uninstall.sh\n' >&2; exit 1; }

step "parando serviços"
systemctl disable --now rtbt.service 2>/dev/null || true
ok "rtbt.service"

step "removendo healthcheck e hook APT"
rm -f /usr/local/bin/rtbth-healthcheck
rm -f /etc/apt/apt.conf.d/99rtbth-dkms
ok "removidos"

step "removendo daemon e hooks"
rm -f /usr/bin/rtbt
rm -f /usr/local/sbin/rtbt-start.sh
rm -f /usr/lib/systemd/system-sleep/rtbt
rm -f /etc/systemd/system/rtbt.service
systemctl daemon-reload
ok "removidos"

step "removendo autoload"
if grep -qxF "$DKMS_PKG" /etc/modules 2>/dev/null; then
    sed -i "/^${DKMS_PKG}\$/d" /etc/modules
    ok "linha ${DKMS_PKG} removida de /etc/modules"
else
    warn "nada a remover em /etc/modules"
fi

step "removendo módulo DKMS"
if dkms status 2>/dev/null | grep -qF "${DKMS_PKG}/${DKMS_VER}"; then
    dkms remove -m "$DKMS_PKG" -v "$DKMS_VER" --all || true
    ok "dkms remove ok"
else
    warn "nenhum DKMS instalado com esse nome"
fi
rm -rf "$DKMS_SRC"
ok "fonte removida de ${DKMS_SRC}"

warn "NÃO fiz rmmod — risco de kernel panic com rtbth em kernels >= 4.4."
printf '\n%s%s reinicie para concluir a remoção. %s\n' "$B" "$Y" "$N"
printf 'Depois do boot, Bluetooth deve voltar ao estado original: sem driver, sem hci0.\n'
printf 'Para reinstalar:  sudo %s/install.sh\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
