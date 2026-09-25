#!/usr/bin/env bash
# healthcheck.sh — verifica se o driver Bluetooth RT3290 está saudável
#
# Uso:
#   sudo ./healthcheck.sh              # relatório completo
#   sudo ./healthcheck.sh --quiet-if-ok  # silencioso se tudo bem (usado no hook APT)
#
# Códigos de saída:
#   0  tudo certo
#   1  driver compilado mas não carregado (pode ser só pré-reboot)
#   2  FALHA: módulo não compilado para o kernel em uso
#
# Por que existe: o rtbth é abandonado pela MediaTek e depende de APIs internas
# do subsistema Bluetooth que mudam entre versões de kernel. Quando o kernel é
# atualizado, o DKMS tenta recompilar sozinho (AUTOINSTALL="yes") — mas pode
# falhar. Sem aviso, você só descobre o problema quando tenta parear um fone.

set -uo pipefail

# dkms e rtbth vivem em /usr/sbin — sem isso o script acusa falha falsa
# quando roda fora do PATH do root.
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

QUIET=0
[ "${1:-}" = "--quiet-if-ok" ] && QUIET=1

DKMS_PKG="rtbth"
DKMS_VER="3.9.6"

KERNEL="$(uname -r)"
KO="/lib/modules/${KERNEL}/updates/dkms/rtbth.ko"
KO_XZ="${KO}.xz"
STATUS_FILE="/var/lib/rtbth-status"
LOG="/var/log/rtbth-healthcheck.log"

say()  { printf '%s\n' "$*"; }
fail() { say "FALHA: $*"; }

# --- coleta ------------------------------------------------------------------
MODULE_OK=0
MODULE_PATH=""
if [ -f "$KO" ]; then MODULE_OK=1; MODULE_PATH="$KO"
elif [ -f "$KO_XZ" ]; then MODULE_OK=1; MODULE_PATH="$KO_XZ"
fi

DKMS_STATE="$(dkms status 2>/dev/null | grep -F "${DKMS_PKG}/${DKMS_VER}" | grep -F "$KERNEL" | head -1)"
DKMS_INSTALLED=0
case "$DKMS_STATE" in
    *": installed") DKMS_INSTALLED=1 ;;
esac

# Se o .ko existe mas o dkms status não veio, o problema é a consulta, não o driver.
DKMS_QUERY_FAILED=0
if [ "$MODULE_OK" -eq 1 ] && [ -z "$DKMS_STATE" ] && ! command -v dkms >/dev/null 2>&1; then
    DKMS_QUERY_FAILED=1
fi

BOUND=0
[ -e /sys/bus/pci/devices/0000:02:00.1/bluetooth ] && BOUND=1
BOUND_TXT="não"; [ "$BOUND" -eq 1 ] && BOUND_TXT="sim"
HCI_LIST="$(ls /sys/class/bluetooth/ 2>/dev/null)"
HCI="$(echo "$HCI_LIST" | tr '\n' ' ' | sed 's/ *$//')"
HCI_COUNT="$(echo "$HCI_LIST" | grep -c . || true)"

# --- avaliação ---------------------------------------------------------------
# Falha grave: não compilou para o kernel em uso. É o caso que o hook do APT
# precisa detectar, porque só aí o Bluetooth morre silenciosamente.
if [ "$DKMS_QUERY_FAILED" -eq 1 ]; then
    if [ "$QUIET" -eq 1 ]; then exit 1; fi
    say "AVISO: não consegui consultar o dkms (rode como root para um diagnóstico completo)."
    say "  O módulo compilado existe em ${KO}, então o driver provavelmente está ok."
    exit 1
fi

if [ "$MODULE_OK" -eq 0 ] || [ "$DKMS_INSTALLED" -eq 0 ]; then
    if [ "$QUIET" -eq 1 ]; then
        MSG="Bluetooth RT3290: driver NÃO compilou para o kernel ${KERNEL}. Reinicie ou reexecute install.sh."
        command -v notify-send >/dev/null 2>&1 && \
            notify-send -u critical "Bluetooth quebrado" "$MSG" >/dev/null 2>&1
        { printf '%s: %s\n' "$(date -Is)" "$MSG"; } >> "$LOG" 2>/dev/null
        echo "BROKEN" > "$STATUS_FILE" 2>/dev/null
        exit 2
    fi
    fail "módulo ausente para o kernel ${KERNEL}"
    say "  .ko esperado em : ${KO}"
    say "  dkms status      : ${DKMS_STATE:-(nenhuma entrada)}"
    say "  veja o log       : dkms build pode ter falhado — /var/lib/dkms/rtbth/3.9.6/build/make.log"
    say "  corrija com      : sudo ${BASH_SOURCE[0]##*/}  ou  sudo ~/src/rtbth-bluetooth/install.sh"
    exit 2
fi

# Tudo compilado. Agora é só estado de runtime — informativo.
if [ "$QUIET" -eq 1 ]; then
    exit 0
fi

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; G=""; Y=""; N=""; fi

say "${B}Bluetooth RT3290 — healthcheck${N}"
say "  kernel          : ${KERNEL}"
if [ "$MODULE_OK" -eq 1 ]; then
    say "  módulo compilado: sim (${MODULE_PATH})"
else
    say "  módulo compilado: NÃO (esperado ${KO}[.xz])"
fi
say "  dkms status     : ${DKMS_STATE:-(nenhuma entrada)}"
say "  função PCI bind : ${BOUND_TXT} (0000:02:00.1)"
say "  adaptadores hci : ${HCI:-nenhum}"

# hci1 sem hci0 é a assinatura de um rtbt reiniciado na marra: o módulo
# numerou o novo device e o bluez ficou preso no antigo.
if [ "$HCI_COUNT" -gt 0 ] && ! echo "$HCI_LIST" | grep -qx hci0; then
    say ""
    say "${Y}  Adaptador numerado errado (${HCI}).${N}"
    say "  O rtbt foi reiniciado sem recarregar o módulo: o hci0 original foi"
    say "  destruído e o bluez ficou apontando para um device morto."
    say "  ${B}Recuperação: reinicie a máquina.${N} (rmmod pode dar kernel panic — README §5.4)"
    exit 1
fi

if [ -z "$HCI" ]; then
    say ""
    say "${Y}  Compilado mas sem adaptador hci.${N}"
    say "  Se o driver acabou de ser instalado, é normal: ${B}reinicie${N} o sistema."
    say "  Se já reiniciou antes e continua assim, provavelmente o módulo"
    say "  não carregou. See: dmesg | grep -iE 'rtbt|hci0'"
    exit 1
fi

say ""
say "${G}Compilado e carregado.${N} (isso não garante que a rádio funcione —"
say "confirme com um scan real: bluetoothctl --timeout 20 scan on)"
exit 0
