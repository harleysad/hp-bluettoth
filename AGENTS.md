# AGENTS.md — rtbth-bluetooth (hp-lnx)

Guia operacional para agentes de IA e para humanos. **Este arquivo é
autoritativo sobre como mexer no driver.** O `README.md` traz a narrativa e a
referência de hardware; não duplica tabela aqui.

---

## 1. O que é isto, e por que existe

O `hp-lnx` (HP Pavilion 11 x360, Celeron N2830) tem um **chip Bluetooth
funcionando** — uma placa combo Ralink/MediaTek **RT3290** — mas **não existe
driver no Debian**. A Mediatek abandonou o suporte, então o BlueZ não enxerga
nenhum adaptador.

Não é firmware faltando nem hardware quebrado. É falta de driver. A solução é o
`rtbth`, driver fora da árvore do kernel, que este repo instala e documenta.

O objetivo do repo é: **após formatar a máquina, `sudo ./install.sh` e reboot
restauram o Bluetooth**, sem internet e mesmo que o GitHub exista.

## 2. ⚠️ Leia antes de agir: estado atual

| Onde | O quê | Situação |
|---|---|---|
| `~/src/rtbth-bluetooth/` | o repo (este diretório) | completo, com a correção da armadilha 5 |
| `/usr/src/rtbth-3.9.6/` | fonte DKMS instalada | correta, mas sem `.git` |
| `/etc/modules` | contém `rtbth` | ❌ **é a configuração quebrada** |
| `/etc/systemd/system/rtbt.service` | versão antiga | ❌ usa `After=systemd-modules-load`, inócuo |
| `/usr/local/sbin/rtbt-start.sh` | versão antiga | ❌ não faz `modprobe`, só mknod + rtbt |
| `/usr/local/bin/rtbth-healthcheck` | **não instalado** | ❌ |

**O `install.sh` deste repo nunca foi executado.** A máquina tem a configuração
antiga, que é justamente a que quebra no boot (armadilha 5). O sintoma atual
esperado é:

```
Bluetooth: hci0: Opcode 0x0401 failed: -12
```

Para consertar: `sudo ~/src/rtbth-bluetooth/install.sh` e depois **reiniciar**.
Nada mais é necessário — o script é idempotente e não mexe no WiFi.

## 3. As cinco armadilhas

Cada uma **quebra o Bluetooth** de um jeito diferente. Todas foram testadas
nesta máquina. Não reintroduza nenhuma.

### 3.1 O hook `install rtbth …; rtbt &` trava o `modprobe`

O `tools/ralink-bt.conf` do upstream é um hook de modprobe que cria o
`/dev/rtbth` e sobe o `rtbt` com `&` no meio da linha de `install`. O `&`
impede o `modprobe` de retornar, e ele **fica travado indefinidamente**.
Substituído por serviço systemd.

### 3.2 Matar o `rtbt` deixa o bluez com um controller morto

O daemon `rtbt` é a ponte userspace. Sem ele o transporte HCI morre. Se o
`hci0` é destruído e recriado como `hci1`, o BlueZ **não** reaponta para o novo
device e passa a responder `No default controller available`.

Por isso `rtbt.service` **não tem `ExecStop`**, e o hook de suspend/resume
**não** mata o `rtbt`. A única recuperação é reiniciar.

### 3.3 SIGINT não funciona neste daemon

Para terminar o `rtbt` use **SIGTERM (`-15`)**. O `pkill -2` (SIGINT) sai com
status **0 sem matar nada** — o daemon da MediaTek ignora o sinal. Isso já
causou um diagnóstico errado durante o desenvolvimento.

### 3.4 `rmmod` pode dar kernel panic

Recarregar o módulo seria a recuperação natural do 3.2, mas `rtbth` tem
**risco documentado de kernel panic** em kernels ≥ 4.4. Por isso: **nunca**
`rmmod`, **nunca** `modprobe` manual, **sempre** reiniciar.

### 3.5 `rtbth` NÃO pode estar no `/etc/modules`

A mais sutil, e a que mais custou tempo.

O comando HCI fica numa `kfifo` no kernel que **só o `rtbt` (userspace)
drena** (`rtbth_bz_hci_send` → `kfifo_in`, em `rtbth_core_init.c`). No `probe`
do módulo o `hci0` é registrado e **o próprio núcleo HCI já enfileira comandos
de inicialização**. Sem reader, eles se acumulam e o controlador fica meio
inicializado.

`bluetoothctl show` então **mente**: diz `Powered: yes`, mas qualquer comando
real falha com `Opcode 0x0401 failed: -12` (`0x0401` = Inquiry, o scan).

O que acontece com autoload:

```
13:07:23  systemd-modules-load → módulo carrega, hci0 registrado
          (núcleo HCI enfileira init; ninguém draining)
          ... 16 segundos sem reader ...
13:07:39  basic.target fecha → rtbt.service sobe → rtbt conecta
13:07:40  bluetooth.service sobe
```

Declarar `After=systemd-modules-load.service` **não resolve**: sem
`DefaultDependencies=no`, o `After=basic.target` implícito de um serviço ganha,
e o `basic.target` só fecha lá por volta dos 16s.

Solução implementada: `rtbth` fora do `/etc/modules`, e o `modprobe rtbth` no
**mesmo `ExecStart`** que sobe o `rtbt` — milissegundos de diferença,
reproduzindo a sequência manual que funcionou.

## 4. Árvore de diagnóstico

Comece sempre por §5. Depois siga pela linha do sintoma.

| Sintoma observado | Causa provável | O que fazer |
|---|---|---|
| `Opcode 0x0401 failed: -12` | armadilha 3.5 — módulo autoloaded cedo demais | tirar `rtbth` do `/etc/modules`, rodar `install.sh`, **reboot** |
| `No default controller available` | armadilha 3.2 — `rtbt` morreu, bluez com device morto | **reboot**. Não tente `rmmod` |
| `ls /sys/class/bluetooth/` mostra só `hci1` | idem — device renumerado | **reboot** |
| `bluetoothctl show` diz `Powered: yes` mas o scan não acha nada | armadilha 3.5, mesmo com aparência de saúde | testar sempre com **scan real**, não com `show` |
| DKMS falha ao compilar em kernel novo | API do subsistema BT mudou no kernel | ver §8 |
| sem `hci0` logo após instalar | forgot de reiniciar | **reboot** |
| Bluetooth morre depois de suspend | fragilidade conhecida do rtbth | `sudo systemctl restart rtbt`; se não resolver, **reboot** |
| `modprobe rtbth` trava o terminal | armadilha 3.1 | `Ctrl-C`, remover `/etc/modprobe.d/ralink-bt.conf` |
| `pkill -2 rtbt` não mata | armadilha 3.3 | usar `pkill -15` |

### Sequência de validação correta

```bash
sudo /usr/local/bin/rtbth-healthcheck          # diagnóstico
sudo bluetoothctl --timeout 20 scan on         # prova real da rádio
```

`bluetoothctl show` **não** basta — ele reporta `Powered: yes` mesmo com o
controlador quebrado (foi exatamente o que enganou durante o
desenvolvimento). Só o scan prova que a rádio transmite e recebe.

## 5. Comandos de diagnóstico (somente leitura, seguros)

```bash
dkms status                                    # rtbth compilado p/ qual kernel?
ls /sys/class/bluetooth/                       # hci0 (bom) vs hci1 (quebrado)
ls -l /lib/modules/$(uname -r)/updates/dkms/    # .ko presente?
lspci -nn | grep -i 1814                       # a placa ainda está lá?
dmesg | grep -iE 'rtbt|hci0|0x3298'            # o que o driver falou?
journalctl -b -u rtbt.service                  # quando o rtbt subiu?
journalctl -b --since "13:07:22" --until "13:07:41"   # janela do boot
systemd-analyze blame | grep rtbt              # o rtbt subiu tarde?
```

## 6. Instalar

```bash
sudo ~/src/rtbth-bluetooth/install.sh
sudo reboot
```

O script é idempotente e **não** faz `modprobe` — ele termina pedindo reboot de
propósito (armadilhas 3.4 e 3.5). Passos que ele executa: instala
`dkms`/`linux-headers-$(uname -r)`/`pciutils`/`bluez`/`libnotify-bin`, copia
`source/rtbth-dkms` para `/usr/src/rtbth-3.9.6`, compila via DKMS, instala
`/usr/bin/rtbt`, cria `rtbt.service` + `rtbt-start.sh` + hook de
suspend/resume, **remove** `rtbth` do `/etc/modules`, instala o healthcheck e o
hook de aviso no APT, e habilita `rtbt` + `bluetooth` no boot.

## 7. Atualizar o kernel

`AUTOINSTALL="yes"` no `dkms.conf` recompila sozinho. O problema é o APT:

```
linux-image-amd64    →  depende só de linux-image-X
linux-headers-amd64  →  depende só de linux-headers-X
```

Um **não** puxa o outro.

- `apt upgrade` / `apt full-upgrade` completo → ambos sobem juntos ✅
- `apt install linux-image-<versão>` solto → **headers não vêm** → DKMS falha ❌

Sempre instale imagem e headers no mesmo comando. O hook em
`/etc/apt/apt.conf.d/99rtbth-dkms` avisa via `notify-send` se o build falhar;
sem daemon de notificação no Wayland, cai para `/var/log/rtbth-healthcheck.log`
e `/var/lib/rtbth-status`.

## 8. Atualizar a fonte do driver

Procedência completa, espelhos e URLs: **`source/PROVENANCE.md`**. Resumo:

- usar **`master`**, **nunca a tag `3.9.6`** (a tag não compila em kernel ≥6.10)
- trocar por esta pasta, conferir `sha256sum -c ../SHA256SUMS` (40 arquivos)
- `install.sh` aborta se o guard `KERNEL_VERSION(6,10,0)` sumir de
  `rtbth_core_bluez.c` — é a salvaguarda

## 9. Desinstalar

```bash
sudo ~/src/rtbth-bluetooth/uninstall.sh
sudo reboot
```

Não faz `rmmod` (armadilha 3.4). Volta ao estado original: sem driver, sem `hci0`.

## 10. Pendências conhecidas

- **Não validado:** a instalação corrigida em boot limpo. A sequência manual
  (modprobe + rtbt colados) foi comprovada — achou "Bedroom TV" a −70 dBm. A
  sequência por autoload comprovadamente falha. O que falta é provar que a
  correção faz o boot funcionar. Depois de rodar `install.sh`: **reboot**, e
  então `bluetoothctl --timeout 20 scan on`.
- **Sem `DefaultDependencies=no`** em `rtbt.service`, por opção: o `basic.target`
  é o momento aceitável agora que o `modprobe` e o `rtbt` estão no mesmo
  `ExecStart`. Se o timing voltar a falhar, mexer aqui primeiro.
- **`rmmod` nunca foi testado** nesta máquina, de propósito. O risco de kernel
  panic vem da comunidade, não foi reproduzido aqui.
- O upstream está parado desde 2025-10-25 e a issue #11 ("Fix DKMS build
  installer") está aberta — o instalador DKMS de lá é frágil, o nosso contorna.

## 11. Glossário

| Termo | Significado aqui |
|---|---|
| `kfifo` | fila em ring buffer no kernel; o `rtbt` drena a de HCI. Se ninguém drena, enche e o driver para. |
| `hci0` / `hci1` | adaptadores Bluetooth numerados. `hci0` = saudável. Só `hci1` = device destruído e renumerado. |
| `DKMS` | recompila módulos de kernel automaticamente quando o kernel muda. |
| `rfkill` | interruptor de software por radio. |
| `Opcode 0x0401` | comando HCI Inquiry — o scan. |
| `-12` / `ENOMEM` | erro devolvido quando a fila HCI não tem espaço. |
| `probe` | momento em que o módulo detecta o dispositivo e registra o `hci0`. |
| `BAR` | bloco de memória/IO do PCI. O BT tinha BAR0 em `0x90700000`. |
| `MOK` | Machine Owner Key — assinatura de módulo DKMS. SecureBoot está desligado aqui. |

## 12. Convenções

- Sudo: `echo 'a' | sudo -S <cmd>` (senha `a`)
- leitura antes de escrita
- `source/rtbth-dkms/**` é código de terceiros: não aplicar patch local sem
  documentar aqui. Não remover `tools/rtbt` (proprietary, mantido para
  instalação offline)
- não duplicar tabela entre este arquivo e o `README.md` — este é operacional,
  aquele é narrativa + referência
