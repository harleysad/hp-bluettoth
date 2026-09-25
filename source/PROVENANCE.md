# Procedência da fonte — rtbth-dkms

> Este diretório contém uma **cópia local** do driver, vendorizada para que a
> instalação funcione **sem rede** e sobreviva ao desaparecimento do upstream.
> Nenhum `.git` aqui: esta página e o `SHA256SUMS` são o registro de origem.

## 1. Origem exata

| Campo | Valor |
|---|---|
| Repositório | `https://github.com/loimu/rtbth-dkms` |
| Branch | `master` |
| Commit | `dea896a66a21c713d4a0b77a0ebc45a891234f21` |
| Data do commit | 2025-10-25 (`"fix condition check (#10)"`) |
| Verificado em | 2026-09-25 |
| Licença declarada | nenhuma no repositório (driver GPL; `tools/rtbt` é proprietary) |

URL para baixar exatamente esta versão:

```bash
curl -L -o dea896a.tar.gz \
  https://github.com/loimu/rtbth-dkms/archive/dea896a66a21c713d4a0b77a0ebc45a891234f21.tar.gz
```

## 2. ⚠️ NÃO use a tag `3.9.6`

O número de versão que aparece no `dkms status` (`rtbth/3.9.6`) **não é a tag
`3.9.6`**. A fonte aqui é `master`, que está à frente das tags.

| Origem | Guard `dev_type` (kernel ≥6.10) | Compila no 6.12? |
|---|---|---|
| tag `3.9.6` (`c1d507f`) | ❌ ausente | **NÃO** — `HCI_PRIMARY undeclared` |
| `master` (`dea896a`) | ✅ presente | **SIM** |

As tags do upstream (`v3.9.4.6`, `3.9.5`, `3.9.6`) são **todas antigas** e
anteriores ao commit que faz o driver funcionar em kernel moderno. Se for
atualizar a fonte, pegue `master` ou um SHA específico, nunca a tag mais recente.

O `install.sh` aborta se o guard sumir — é a salvaguarda contra esse erro.

## 3. Verificar integridade

```bash
cd ~/src/rtbth-bluetooth/source/rtbth-dkms
sha256sum -c ../SHA256SUMS
```

40 arquivos, deve terminar com `40 arquivos OK` e nenhum `FAILED`.

Contra o upstream (precisa rede):

```bash
curl -sL -o /tmp/dea896a.tar.gz \
  https://github.com/loimu/rtbth-dkms/archive/dea896a66a21c713d4a0b77a0ebc45a891234f21.tar.gz
mkdir -p /tmp/chk && tar -xzf /tmp/dea896a.tar.gz -C /tmp/chk
diff -rq /tmp/chk/rtbth-dkms-dea896a* ~/src/rtbth-bluetooth/source/rtbth-dkms
```

Única diferença esperada: `.gitignore`, que foi removido de propósito (o
`.gitignore` deste repo o exclui). Qualquer outra diferença = fonte adulterada.

## 4. Achar versão mais nova

O upstream está parado em `dea896a` desde 2025-10-25 (verificado em 2026-09-25).
Para checar se andou:

```bash
git ls-remote https://github.com/loimu/rtbth-dkms HEAD master
```

Ou pela API, sem clonar:

```bash
curl -s https://api.github.com/repos/loimu/rtbth-dkms/commits/master \
  | grep -E '"sha"|"date"'
```

Só o commit que está em `master` interessa — as tags estão defasadas (§2).

**Antes de trocar a fonte**, confira se o novo commit ainda compila. O driver
depende de APIs internas do subsistema Bluetooth que a upstream do Linux muda
com frequência; `git log` do upstream e o histórico das issues ajudam
(`https://github.com/loimu/rtbth-dkms/issues`).

## 5. Espelhos, em ordem de recência

Se o repositório oficial sumir, tente nesta ordem:

| Repo | Último push | Nota |
|---|---|---|
| `loimu/rtbth-dkms` | 2025-10-25 | oficial, o que está vendorizado aqui |
| `Vict0rTesla/rtbth-dkms` | 2025-11-05 | mais recente; tem correções 6.x |
| `sudomgomal/rtbth-dkms` | 2025-01-09 | — |
| `ry-diffusion/rtbth-ralink-3290-linux-dkms` | 2024-09-07 | nome diferente |

Buscar todos: `https://api.github.com/repos/loimu/rtbth-dkms/forks?sort=newest`

**Plano C, se todos sumirem:** a cópia local neste diretório. Ela é a fonte da
verdade do `install.sh` e não depende de nada externo. Não descarte.

## 6. Avisos sobre issues abertas

| # | Aberta desde | Título | Relevância |
|---|---|---|---|
| #11 | 2026-08-11 | Fix DKMS build installer | O instalador DKMS do upstream é frágil. Nosso `install.sh` contorna. |
| #1 | 2016-12-05 | Sleep/Wakeup workaround script | Origem do `tools/49rtbt`, que **não** usamos (ver AGENTS.md, armadilha 2). |
