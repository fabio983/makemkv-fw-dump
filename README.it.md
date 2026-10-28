# makemkv-fw-dump

[English](README.md) | **Italiano**

Un piccolo script che genera il **dump del firmware del lettore Blu-ray** per MakeMKV, il file di cui le versioni recenti di MakeMKV hanno bisogno per non bloccarsi sui Blu-ray.

È nato per risolvere un problema della mia installazione di [Automatic Ripping Machine (ARM)](https://github.com/automatic-ripping-machine/automatic-ripping-machine), ma il problema sta in MakeMKV, quindi copre due casi d'uso:

- **Chi usa ARM:** lo script trova il container di ARM, lo ferma mentre lavora e può installare il dump nella cartella `.MakeMKV` di ARM al posto tuo (`--install`).
- **Chi usa `makemkvcon` senza ARM** (script propri, oppure ARM non ancora installato): passi la chiave MakeMKV con `-k` e copi il dump nella tua cartella `~/.MakeMKV`. Vedi [Senza ARM](#senza-arm).

Dietro le quinte compila una versione precedente di MakeMKV (1.17.6) in un container Docker usa e getta, legge un disco, recupera il file `dump_FW_*.tgz` creato da MakeMKV e fa pulizia. Sull'host non viene installato niente, a parte un'immagine Docker che puoi rimuovere alla fine.

## Il problema

Con le versioni recenti di MakeMKV (dalla 1.17.7 in poi) ARM può bloccarsi sui Blu-ray. Il problema è segnalato nella [issue ARM #1545](https://github.com/automatic-ripping-machine/automatic-ripping-machine/issues/1545). Sintomi tipici:

- il log del job di ARM si ferma subito dopo `Starting MakeMKV rip`;
- `makemkvcon` resta al 100% di CPU e non finisce mai;
- il lettore non gira e non legge;
- lanciando `makemkvcon` a mano compare `Downloading latest SDF ...` e poi nient'altro;
- i DVD di solito funzionano, i Blu-ray no.

Nei miei test il pezzo mancante era il **dump del firmware** del lettore (`dump_FW_<ID>.tgz` nella cartella `.MakeMKV`). Con quel solo file accanto a `settings.conf`, MakeMKV 1.18.4 dentro ARM è partito subito. Le versioni precedenti di MakeMKV creano il dump in automatico alla prima lettura di un disco: lo script fa esattamente questo, in un ambiente isolato.

Lo stesso blocco si è presentato con MakeMKV 1.18.4 installato direttamente sull'host, fuori da ARM: il dump serve quindi a qualsiasi configurazione con `makemkvcon`, non solo ad ARM.

## Requisiti

- Host Linux con Docker (va bene quello su cui gira ARM)
- `lsscsi` e `udevadm` (`sudo apt install lsscsi`)
- Un Blu-ray da leggere (va bene qualsiasi disco: il dump dipende dal lettore, non dal disco)
- Una chiave MakeMKV (va bene la chiave beta gratuita). Se ARM è installato, lo script la legge dal `settings.conf` di ARM; altrimenti passala con `-k`
- ARM **non** è necessario: vedi [Senza ARM](#senza-arm)
- Connessione a internet per scaricare MakeMKV 1.17.6 da [makemkv.com/download/old](https://www.makemkv.com/download/old/)

## Uso

```bash
chmod +x makemkv-fw-dump.sh
sudo ./makemkv-fw-dump.sh
```

Lo script:

1. trova il container di ARM e lo ferma, così ARM non si prende il disco. Usa `docker stop` e, alla fine (anche in caso di errori), `docker start`: il container mantiene la sua configurazione originale;
2. trova il lettore Blu-ray e il relativo device `sg`;
3. legge la chiave MakeMKV dal `settings.conf` di ARM, nella cartella dell'host montata su `/home/arm` nel container;
4. compila MakeMKV 1.17.6 in un'immagine Docker (qualche minuto, solo la prima volta);
5. ti chiede di inserire un Blu-ray e lo legge con una cartella `.MakeMKV` pulita che contiene solo la chiave;
6. salva il dump e il log completo in `./makemkv-fw-dump-AAAAMMGG-HHMMSS/` e lo confronta con l'eventuale dump già presente in ARM.

**Non inserire il disco prima che lo script te lo chieda**, altrimenti ARM potrebbe avviare un job ed espellere il disco quando viene fermato.

Di default il dump **non** viene copiato nella cartella di ARM, così puoi verificarlo prima. Aggiungi `--install` per copiarlo lì con il proprietario corretto.

### Opzioni

| Opzione | Descrizione |
|---|---|
| `-d, --device /dev/srX` | Lettore da usare. Se omesso, il lettore Blu-ray viene scelto in automatico quando ce n'è uno solo. |
| `-k, --key CHIAVE` | Chiave MakeMKV. Se omessa, viene letta dal `settings.conf` di ARM. |
| `-o, --output CARTELLA` | Cartella di output per dump e log. |
| `-c, --container NOME` | Nome del container di ARM. Se omesso, lo script cerca un container attivo chiamato `arm`, `arm-rippers` o `automatic-ripping-machine`, oppure basato su un'immagine il cui nome contiene `automatic-ripping-machine`. |
| `--install` | Copia il dump anche nella cartella `.MakeMKV` di ARM, con lo stesso proprietario della cartella. |
| `--remove-image` | Rimuove l'immagine Docker alla fine. |
| `-h, --help` | Mostra l'aiuto. |

Variabili d'ambiente: `MKV_VERSION` (default `1.17.6`), `ARM_CONTAINER` (come `-c`), `ARM_MAKEMKV_DIR` (cartella `.MakeMKV` di ARM sull'host, se non si riesce a ricavarla dal container; default `/home/arm/.MakeMKV`), `TIMEOUT` in secondi (default `600`).

Se ARM è installato senza Docker, lo script non può fermarlo: fermalo tu prima di lanciare lo script.

I messaggi dello script sono in inglese.

### Esempio di output

```
==> Read summary
    MakeMKV v1.17.6 linux(x64-release) started
    Using direct disc access mode
    Processing BD+ code, please be patient - this may take up to few minutes
    BD+ code processed, got 1 FUT(s) for 1 clip(s)
    Operation successfully completed
    TCOUNT:20

==> Dump created: /home/user/makemkv-fw-dump-20261027-205311/dump_FW_74E1F1B75CCA043A0290.tgz
```

## Usare il dump con ARM

1. Copia il dump nella cartella `.MakeMKV` di ARM (quella montata come `/home/arm` nel container) e assegnalo all'utente di ARM:

   ```bash
   sudo cp makemkv-fw-dump-*/dump_FW_*.tgz /home/arm/.MakeMKV/
   sudo chown $(stat -c '%u:%g' /home/arm/.MakeMKV) /home/arm/.MakeMKV/dump_FW_*.tgz
   ```

2. Facoltativo: aggiungi queste due righe a `/home/arm/.MakeMKV/settings.conf`, così MakeMKV non controlla gli aggiornamenti e non scarica i dati SDF a ogni avvio. L'aggiornamento della chiave fatto da ARM modifica solo la riga `app_Key`, quindi restano:

   ```
   cfg_UpdateEnable = "0"
   cfg_SdfDownload = "0"
   ```

3. Inserisci un Blu-ray: il rip dovrebbe partire dopo l'attesa per l'intervento manuale di ARM.

## Senza ARM

Lo script funziona anche se ARM non è ancora installato, o se usi `makemkvcon` con i tuoi script. In quel caso non c'è un `settings.conf` da cui leggere la chiave, quindi passala con `-k`:

```bash
sudo ./makemkv-fw-dump.sh -k "T-XXXXXXXXXXXX"
```

Non usare `--install`: il dump resta nella cartella di output. Poi:

- **Se installi ARM dopo:** avvia ARM una volta, così crea la sua cartella `.MakeMKV`, e copia lì il dump come spiegato in [Usare il dump con ARM](#usare-il-dump-con-arm). Così ARM funziona con i Blu-ray fin dal primo rip.
- **Con i tuoi script `makemkvcon`:** copia il dump nella cartella `.MakeMKV` nella home dell'utente che lancia `makemkvcon` (ad esempio `~/.MakeMKV/`, oppure `/root/.MakeMKV/` se gira come root), accanto a `settings.conf`:

  ```bash
  mkdir -p ~/.MakeMKV
  cp makemkv-fw-dump-*/dump_FW_*.tgz ~/.MakeMKV/
  ```

## Note

- Il dump è **specifico del lettore** (l'ID è nel nome del file). Se cambi lettore, rilancia lo script.
- Basta farlo una volta per lettore. Tieni una copia della cartella `.MakeMKV` nei tuoi backup.
- I DVD non sono interessati dal problema.
- Per provare MakeMKV dentro ARM a mano, lancialo con l'utente di ARM: `sudo docker exec -u arm arm makemkvcon -r info dev:/dev/srX`. Da root ottieni `This application version is too old`, perché root non ha la chiave.

## Testato su

- HP EliteDesk 800 G3 SFF, Ubuntu Server 26.04 LTS, Docker
- ARM 2.24.4 (MakeMKV 1.18.4 nel container)
- Pioneer BDR-TD04 in un case USB

Segnalazioni con altri lettori e configurazioni sono benvenute: apri una issue allegando il log (`makemkvcon.log` nella cartella di output).

## Avvertenze

Questo progetto non è affiliato a MakeMKV né al progetto Automatic Ripping Machine. Automatizza solo la compilazione e il primo avvio di una versione pubblica precedente di MakeMKV. Usalo con dischi di tua proprietà e nel rispetto delle leggi del tuo paese.

## Licenza

[MIT](LICENSE)
