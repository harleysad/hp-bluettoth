# Bluetooth RT3290 (rtbth) — hp-lnx

> Driver Bluetooth para a placa combo Ralink/MediaTek **RT3290** do `hp-lnx`
> (HP Pavilion 11 x360, Debian 13 trixie). Repo offline: instalar é um comando.
> Gerado em 2026-09-25 a partir de levantamento real da máquina.

---

## 1. O problema, em uma frase

O Bluetooth **existe** no hardware mas **não funciona** no Debian porque a
Mediatek abandonou o suporte, então nenhum driver mainline reconhece o chip
`1814:3298` e o BlueZ não enxerga adaptador nenhum.

Não é falta de firmware nem defeito — é falta de driver.

## 2. O que foi medido nesta máquina

| Item | Valor |
|---|---|
| Placa combo | Ralink/MediaTek **RT3290** (subsystem HP `103C:191C` / "RT3290LE"), Mini PCIe half-card |
| Função WiFi | `02:00.0` = `1814:3290` → `rt2800pci` ✅ funciona (`wlp2s0f0`, fw `rt3290.bin` v0.37) |
| Função Bluetooth | `02:00.1` = `1814:3298` → **sem driver mainline** ❌ |
| Endereço do adaptador | `74:29:AF:A7:46:06` (BT), `74:29:AF:A7:46:05` (WiFi) — MACs adjacentes, typical de combo |
| Fabricante BT | `0x005b` (91) = MediaTek |
| Versão BT | 4.0 |

A CPU é um **Intel Celeron N2830** (Bay Trail), que **não** tem Bluetooth
integrado. Todo o BT da máquina vem da placa combo.

## 3. Por que o mainline não cobre

```
$ grep -c v00001814d00003298 /lib/modules/$(uname -r)/modules.alias
0
```

O `btusb` não serve (é função PCIe, não USB). Não existe driver no Debian. A
única solução é o **`rtbth`**, fora da árvore, do repositório
`loimu/rtbth-dkms`.

> ⚠️ O upstream **não** é suportado pela Mediatek ("Support was discontinued").
> É um driver órfão. Ele depende de APIs internas do subsistema Bluetooth que
> mudam entre versões de kernel — leia §7 antes de atualizar o kernel.

## 4. Conteúdo deste repo

```
rtbth-bluetooth/
├── README.md            este arquivo
├── install.sh           instalador idempotente, 100% offline
├── healthcheck.sh       diagnóstico (também instalado em /usr/local/bin)
├── uninstall.sh         rollback
└── source/rtbth-dkms/   fonte vendorizada (1,9 MB) — master @ dea896a
```

**Nada aqui precisa de rede.** A fonte e o binário `rtbt` estão vendorizados,
então o repo funciona como backup offline completo.

### Sobre a versão da fonte — leia isto

A fonte em `source/rtbth-dkms/` é o branch **`master`** do upstream, no commit
`dea896a66a21c713d4a0b77a0ebc45a891234f21` (2025-10-25). **Não** é a tag
`3.9.6` do upstream — apesar do nome que aparece no `dkms status`.

Isso é deliberado e importa muito:

| Origem | Guard `dev_type` (kernel ≥6.10) | Compila no 6.12? |
|---|---|---|
| tag `3.9.6` (`c1d507f`) | ❌ ausente | **NÃO** — falha com `HCI_PRIMARY undeclared` |
| `master` (`dea896a`) | ✅ presente | **SIM** |

Se você pinar na tag `3.9.6` — o comportamento "óbvio" — a instalação quebra.
O master tem ainda o commit `bc84818f` ("Update for kernel 6.16+") que troca
`del_timer_sync` por `timer_shutdown_sync`, então ele é **mais** à prova de
kernel novo que a tag.

O `install.sh` verifica se a fonte tem esse guard e **aborta** se não tiver.

## 5. Instalação

```bash
sudo ~/src/rtbth-bluetooth/install.sh
sudo reboot
```

Idempotente — pode rodar de novo a qualquer momento.

### As cinco armadilhas (não descubra no meio do caminho)

Estas coisas foram testadas nesta máquina e **quebram** o Bluetooth se você as
fizer. Estão comentadas no `install.sh` também, para quem editar depois:

1. **Nunca** crie o hook `install rtbth …; rtbt &` do `modprobe.d/ralink-bt.conf`
   do upstream. Ele **trava o `modprobe` indefinidamente** (o `&` no meio da
   linha impede o `modprobe` de retornar). Substituído por um serviço systemd.

2. **Não coloque `ExecStop` no serviço** que mate o `rtbt`. Matar o daemon
   derruba o transporte HCI: o `hci0` desaparece, o módulo cria um `hci1`, e o
   BlueZ fica com um controller morto respondendo
   `No default controller available`. Foi exatamente o que aconteceu durante a
   validação. O serviço de propósito **não tem** `ExecStop`.

3. **Use SIGTERM (`-15`), nunca SIGINT (`-2`)** para terminar o `rtbt`. O
   daemon da MediaTek **ignora** SIGINT — o `pkill -2` sai com status 0 sem
   matar nada.

4. **Reinicie; não use `rmmod`.** Recarregar o módulo é a única forma de
   recuperar o HCI tras a armadilha 2, e o `rmmod` de `rtbth` tem **risco
   documentado de kernel panic** em kernels ≥ 4.4. Por isso o `install.sh`
   termina pedindo reboot e não faz `modprobe` sozinho.

5. **`rtbth` NÃO pode estar no `/etc/modules`.** Esta é a mais sutil e a que
   mais custou tempo. Explicada abaixo.

### Por que o módulo não pode ser autoloaded (armadilha 5)

O comando HCI fica numa `kfifo` no kernel que **só o `rtbt` (userspace) drena**
(`rtbth_bz_hci_send` → `kfifo_in`, em `rtbth_core_init.c:1746`).

No `probe` do módulo o `hci0` é registrado **e o próprio núcleo HCI já enfileia
comandos de inicialização**. Se o `rtbt` não estiver lendo nesse instante, esses
comandos se acumulam e o controlador fica meio inicializado. Resultado: o
`bluetoothctl show` mente e diz `Powered: yes`, mas qualquer comando real falha:

```
Bluetooth: hci0: Opcode 0x0401 failed: -12
```

`0x0401` é o **Inquiry** (o scan). O `-12` é o erro devolvido ao núcleo.

Foi exatamente o que aconteceu no primeiro boot testado:

```
13:07:23  systemd-modules-load  → módulo carrega, hci0 registrado
          (núcleo HCI enfileira init; ninguém draining)
          ... 16 segundos sem reader ...
13:07:39  rtbt.service → rtbt conecta     ← tarde demais
13:07:40  bluetooth.service sobe
```

O `rtbt.service` declarava `After=systemd-modules-load.service`, mas isso não
funciona: sem `DefaultDependencies=no`, o `After=basic.target` **implícito** de
um serviço ganha, e o `basic.target` só fecha lá por volta de 13:07:39.

Por isso o `install.sh`:

- **não** escreve `rtbth` no `/etc/modules`
- faz o `modprobe rtbth` e sobe o `rtbt` **no mesmo `ExecStart`**, com
  milissegundos de diferença — reproduzindo a sequência manual que funcionou

Confira depois de um boot:

```bash
systemd-analyze blame | grep rtbt
sudo /usr/local/bin/rtbth-healthcheck
```

Se o `rtbt` aparecer muito abaixo na lista, o `modprobe` está longe demais.


## 6. Verificação

```bash
sudo /usr/local/bin/rtbth-healthcheck
```

| Código | Significado |
|---|---|
| `0` | tudo certo — módulo compilado, carregado, com adaptador `hci0` |
| `1` | compilado mas sem `hci0` — provavelmente só ainda não reiniciou |
| `2` | **falha** — não compilou para o kernel em uso |

Para confirmar que a rádio funciona de verdade, não basta o `hci0` existir:

```bash
sudo bluetoothctl power on
sudo bluetoothctl --timeout 20 scan on
```

Se aparecerem dispositivos com RSSI variando (ex. `-70` a `-93 dBm`), a rádio
está transmitindo e recebendo de verdade. Foi o que valizou a instalação.

## 7. Atualização de kernel

O `dkms.conf` tem `AUTOINSTALL="yes"`, então o DKMS **recompila sozinho** a
cada kernel novo instalado. Você não compila nada à mão.

### A pegadinha do APT

Os metapackages são independentes:

```
linux-image-amd64    →  depende só de linux-image-X
linux-headers-amd64  →  depende só de linux-headers-X
```

Um **não** puxa o outro. Então:

- `apt upgrade` / `apt full-upgrade` completo → os dois sobem juntos ✅
- `apt install linux-image-6.12.120+deb13-amd64` (kernel solto) → **os headers
  não vêm** → o DKMS falha e o BT morre nesse kernel ❌

Se precisar instalar um kernel específico, instale os headers na sequência:

```bash
sudo apt install linux-headers-6.12.120+deb13-amd64 linux-image-6.12.120+deb13-amd64
```

### Aviso automático

O `install.sh` instala um hook em `/etc/apt/apt.conf.d/99rtbth-dkms` que roda o
healthcheck após cada operação do APT. Se o driver quebrar num kernel novo,
você recebe um `notify-send` na hora, em vez de descobrir dias depois quando
for parear um fone. Se não houver daemon de notificação no Wayland, cai para
`/var/log/rtbth-healthcheck.log` e para `/var/lib/rtbth-status`.

### Se quebrar mesmo assim

```bash
sudo ~/src/rtbth-bluetooth/install.sh    # recopia a fonte e recompila
```

Se o build falhar, provavelmente o upstream ainda não cobriu a API nova do
kernel. Aí o caminho é:
- ver `make.log`: `/var/lib/dkms/rtbth/3.9.6/build/make.log`
- atualizar a fonte vendorizada para um master mais novo
- ou usar um **dongle USB Bluetooth** (~R$40), que é suportado nativamente e
  resolve de vez.

### Suspend/resume

O hook em `/usr/lib/systemd/system-sleep/rtbt` só alterna o `rfkill` — ele
**não** mata o `rtbt` (mesma razão da armadilha 2). Se o BT morrer depois de
suspender:

```bash
sudo systemctl restart rtbt     # e se não resolver, mais um reboot
```

## 8. Desinstalar

```bash
sudo ~/src/rtbth-bluetooth/uninstall.sh
sudo reboot
```

Não faz `rmmod` (armadilha 4). Volta a máquina ao estado original: sem driver,
sem `hci0`.

## 9. Referência técnica

### Config space da função Bluetooth (medido)

```
02:00.1 Bluetooth [0d11]: Ralink corp. RT3290 Bluetooth [1814:3298]
    Subsystem: Hewlett-Packard Company Device 191c
    command register = 0x0003   (Memory Space + I/O Space enable)
    BAR0           = 0x90700000 (64 KB MMIO atribuído)
    alias no módulo= pci:v00001814d00003298sv*sd*bc*sc*i*
    vermagic       = 6.12.107+deb13-amd64
```

O `enable: 0` que aparece em `/sys/bus/pci/devices/0000:02:00.1/enable` **não**
significa hardware morto — significa apenas "nenhum driver reivindicou ainda".
O config space prova que o chip estava (e está) energizado e mapeado.

> Esse foi um erro de leitura no primeiro levantamento: o dump de `resource`
> mostrava BARs não-zero, e a conclusão de "dispositivo desativado" estava
> errada. Leia o config space (`lspci -xxx`), não só o sysfs.

### Arquivos que o `install.sh` toca

| Caminho | Papel |
|---|---|
| `/usr/src/rtbth-3.9.6/` | fonte (DKMS) |
| `/usr/bin/rtbt` | daemon closed-source MediaTek |
| `/usr/local/sbin/rtbt-start.sh` | cria `/dev/rtbth` e inicia o daemon |
| `/etc/systemd/system/rtbt.service` | unidade systemd (sem `ExecStop`) |
| `/usr/lib/systemd/system-sleep/rtbt` | hook de suspend/resume |
| `/etc/modules` | autoload do módulo |
| `/usr/local/bin/rtbth-healthcheck` | diagnóstico |
| `/etc/apt/apt.conf.d/99rtbth-dkms` | hook de aviso no APT |

### Upstream

- Repo: `https://github.com/loimu/rtbth-dkms`
- Versão vendorizada: `master` @ `dea896a` (2025-10-25)
- Licença: o driver é GPL; o binário `tools/rtbt` é **closed-source MediaTek, sem
  licença declarada**. Ele está vendorizado neste repo para uso pessoal e
  backup — não há redistribuição pública envolvida.

## 10. Companion docs

Não duplica: `boot-setup/BOOT-REFERENCE.md` (cadeia de boot e serviços),
`boot-setup/HARDWARE-REFERENCE.md` (inventário da máquina).
