#!/usr/bin/env bash
# install.sh — instala o driver Bluetooth RT3290 (rtbth) no hp-lnx
#
# Uso:  sudo ./install.sh
# Idempotente: pode rodar quantas vezes quiser.
# Offline: usa a fonte vendorizada em source/rtbth-dkms — não precisa de rede.
#
# NÃO rode modprobe rtbth manualmente no final. Este script termina pedindo
# reinício de propósito. Ver README.md §5.

set -euo pipefail

DKMS_PKG="rtbth"
DKMS_VER="3.9.6"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDORED="${SRC_DIR}/source/rtbth-dkms"
DKMS_SRC="/usr/src/${DKMS_PKG}-${DKMS_VER}"

# --- saída -------------------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s  XX%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# --- pré-condições -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "rode como root: sudo ./install.sh"
[ -d "$VENDORED" ]   || die "fonte vendorizada não encontrada em $VENDORED"
[ -f "$VENDORED/dkms.conf" ] || die "dkms.conf ausente — repo incompleto?"
[ -x "$VENDORED/tools/rtbt" ] || die "tools/rtbt ausente — repo incompleto?"

# O driver só faz sentido nesta máquina. Falha cedo em vez de instalar às cegas.
if [ -d /sys/bus/pci/devices ]; then
    if ! grep -ql 3298 /sys/bus/pci/devices/*/device 2>/dev/null; then
        die "nenhum dispositivo PCI 1814:3298 (RT3290 Bluetooth) encontrado nesta máquina"
    fi
    ok "hardware RT3290 Bluetooth detectado"
fi

# O driver é específico do chip. Compilar em qualquer outra máquina só produz
# um .ko que nunca vai carregar.
step "verificando compatibilidade da fonte com o kernel $(uname -r)"
if grep -q 'KERNEL_VERSION(6,10,0)' "${VENDORED}/rtbth_core_bluez.c" 2>/dev/null; then
    ok "fonte contém o guard dev_type (necessário p/ kernel >= 6.10)"
else
    warn "fonte NÃO contém o guard dev_type — vai falhar em kernel >= 6.10."
    warn "Isso indica a tag 3.9.6 do upstream, que é mais antiga que master."
    warn "O certo é master (commit dea896a), vendorizado nesta pasta."
    [ "${RTBTH_FORCE:-0}" = "1" ] || die "abortado. Use RTBTH_FORCE=1 para forçar mesmo assim."
fi

# --- dependências ------------------------------------------------------------
step " instalando dependências"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y dkms "linux-headers-$(uname -r)" pciutils bluez libnotify-bin
ok "dkms, headers do kernel, pciutils, bluez, libnotify-bin"

# --- fonte -------------------------------------------------------------------
step " instalando fonte em ${DKMS_SRC}"
dkms remove -m "$DKMS_PKG" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
rm -rf "$DKMS_SRC"
mkdir -p "$(dirname "$DKMS_SRC")"
cp -a "$VENDORED" "$DKMS_SRC"
# o .gitignore do upstream não tem utilidade aqui e atrapalha o diff
rm -f "${DKMS_SRC}/.gitignore"
ok "fonte copiada"

# --- compilar ----------------------------------------------------------------
step "compilando módulo via DKMS"
dkms add -m "$DKMS_PKG" -v "$DKMS_VER"
dkms build  -m "$DKMS_PKG" -v "$DKMS_VER" -k "$(uname -r)"
dkms install -m "$DKMS_PKG" -v "$DKMS_VER" -k "$(uname -r)"
ok "módulo instalado em /lib/modules/$(uname -r)/updates/dkms/"

# --- daemon ------------------------------------------------------------------
# O binário rtbt é closed-source da MediaTek. Ele fala com o driver via
# /dev/rtbth e é quem de fato liga o controlador.
step "instalando daemon rtbt"
install -m 0755 -o root -g root "${VENDORED}/tools/rtbt" /usr/bin/rtbt
ok "/usr/bin/rtbt"

# --- serviço systemd ---------------------------------------------------------
step "criando rtbt.service"
cat > /etc/systemd/system/rtbt.service <<'UNIT'
[Unit]
Description=Ralink/MediaTek RT3290 Bluetooth userspace daemon
Documentation=file:/usr/local/lib/rtbth-bluetooth/README.md
# O script faz o modprobe do rtbth e sobe o rtbt em seguida. Não declaramos
# After=systemd-modules-load.service de propósito: em um serviço sem
# DefaultDependencies=no, o After=basic.target implícito ganha e o serviço
# só sobe ~16s depois do módulo — e essa janela quebra o controlador.
# Antes=bluetooth.service garante que o bluez só entra depois do daemon.
Before=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rtbt-start.sh
# SEM ExecStop, de propósito.
# Matar o rtbt derruba o transporte HCI e deixa o bluez apontando para um
# controller morto: o hci0 some, o modulo cria um hci1 e o bluetoothctl passa
# a responder "No default controller available". O unico jeito de recuperar e
# recarregar o modulo (rmmod/modprobe), que tem risco documentado de kernel
# panic em kernels >= 4.4. Por isso nao automatizamos isso.

[Install]
WantedBy=multi-user.target
UNIT

# O hook original do upstream (modprobe.d/ralink-bt.conf) usava
# "install rtbth ...; rtbt &" — isso TRAVA o modprobe indefinidamente.
# Substituído por um serviço systemd, que faz o mesmo trabalho sem travar.
#
# A ORDEM AQUI É CRÍTICA: modprobe e rtbt precisam começar colados, com
# milissegundos de diferença. Ver README §5.5.
cat > /usr/local/sbin/rtbt-start.sh <<'START'
#!/bin/sh
set -e

# Carrega o módulo e já em seguida sobe o daemon. A distância entre estes dois
# comandos tem que ser mínima: no probe do módulo o hci0 é registrado e o
# núcleo HCI já enfileira comandos de inicialização. Se o rtbt (que é quem
# drena essa fila) não estiver lendo, o controlador fica meio inicializado e
# depois responde "Opcode 0x0401 failed: -12" em qualquer inquiry/scan.
modprobe rtbth

if [ ! -e /dev/rtbth ]; then
    rm -f /dev/rtbth
    mknod /dev/rtbth c 192 0
    chmod 666 /dev/rtbth
fi

/usr/bin/rtbt &
START
chmod 0755 /usr/local/sbin/rtbt-start.sh
ok "serviço e script de arranque"

# --- suspend/resume ----------------------------------------------------------
# Só alterna o rfkill. NÃO mata o rtbt — pelo mesmo motivo do ExecStop acima.
step "criando hook de suspend/resume"
mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/rtbt <<'SLEEP'
#!/bin/sh
# O rtbt ignora SIGINT (-2). Se precisar mesmo terminar, use SIGTERM (-15).
case "$1" in
    pre)  rfkill block bluetooth   2>/dev/null || true ;;
    post) rfkill unblock bluetooth 2>/dev/null || true ;;
esac
exit 0
SLEEP
chmod 0755 /usr/lib/systemd/system-sleep/rtbt
ok "hook instalado"

# O rtbth NÃO vai em /etc/modules. Ver README §5.5 — o autoload do módulo é
# justamente o que quebra o driver no boot.
step "garantindo que o módulo NÃO é autoloaded (/etc/modules)"
if grep -qxF "$DKMS_PKG" /etc/modules 2>/dev/null; then
    sed -i "/^${DKMS_PKG}\$/d" /etc/modules
    ok "linha ${DKMS_PKG} removida de /etc/modules"
else
    ok "/etc/modules já está limpo"
fi

# --- healthcheck -------------------------------------------------------------
step "instalando healthcheck"
install -m 0755 -o root -g root "${SRC_DIR}/healthcheck.sh" /usr/local/bin/rtbth-healthcheck
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99rtbth-dkms <<HOOK
// avisa se o DKMS falhar ao compilar num kernel novo
DPkg::Post-Invoke { "/usr/local/bin/rtbth-healthcheck --quiet-if-ok"; };
HOOK
ok "healthcheck + hook APT"

# --- ativar ------------------------------------------------------------------
systemctl daemon-reload
systemctl enable rtbt.service >/dev/null 2>&1
systemctl enable bluetooth.service >/dev/null 2>&1 || true
ok "rtbt e bluetooth habilitados no boot"

printf '\n%s%s reinicie o sistema para ativar o Bluetooth. %s\n' "$B" "$Y" "$N"
printf 'Não rode modprobe rtbth à mão: isso deixa o bluez com um controller morto (README §5).\n'
printf 'Depois do boot, valide com:  sudo /usr/local/bin/rtbth-healthcheck\n'
