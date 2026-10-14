# Debian Kiosk per business center

Script interattivo che trasforma un'installazione **Debian 12/13 netinst minimale** (senza desktop) in un PC kiosk con browser a schede a schermo pieno, pensato per i business center degli hotel. Una macchina alla volta, da GitHub.

Stack: **Xorg + Openbox** (nessun desktop environment) + **Chromium** o **Firefox ESR** a scelta durante l'installazione.

> **Stato dei test.** Lo script supera `bash -n` e `shellcheck`, e le funzioni interattive, i file generati (XML/JSON/script), la modifica delle `sources.list`/GRUB e la pulizia della sessione sono stati verificati in un sandbox. **Non è stato provato su hardware reale né in una VM con Debian completo**: prima di usarlo su un PC vero, fai una prova in VirtualBox/Proxmox e poi su una macchina di test.

## Installazione

1. Installa Debian netinst. Nella schermata *Software selection* **deseleziona ogni ambiente desktop** e lascia solo *SSH server* (opzionale) e *standard system utilities*. Crea l'utente amministratore normale (non quello kiosk).
2. Accedi come admin ed esegui:

   ```bash
   wget -O kiosk-setup.sh https://github.com/EmEmArBee/kioskian/blob/main/kiosk-setup.sh
   sudo bash kiosk-setup.sh
   ```

   Senza `sudo` installato: `su -` e poi `bash kiosk-setup.sh`. Scarica sempre il file e poi eseguilo (non `curl | bash`).
3. Rispondi alle domande, controlla il riepilogo, conferma. Alla fine la macchina si riavvia da sola (se hai scelto di sì) e parte il kiosk.

Lo script si può rilanciare: sovrascrive i propri file. Il log è in `/var/log/kiosk-setup.log`.

## Cosa chiede

| Domanda | Default |
|---|---|
| Nome utente kiosk (senza password, autologin) | `kiosk` |
| Browser (Chromium / Firefox ESR) | Chromium |
| Pagina iniziale | `https://www.google.com` |
| Minuti di inattività prima del reset | 15 |
| Hostname | quello attuale |
| USB in sola lettura | sì |
| Stampa (CUPS) e, a parte, tutti i driver | sì / no |
| Audio (PipeWire) | sì |
| Font extra (asiatici, arabi, indiani, emoji, ~200 MB) | sì |
| SSH: utente admin e chiave pubblica | sì |
| Wi-Fi precompilato (SSID e password) | no |
| Rimuovere lingue e man page inutili | sì |
| Ottimizzare il boot | sì |
| Riavvio automatico a fine installazione | sì |

## Cosa fa il kiosk

- **Autologin** sulla tty1 e avvio di X solo per l'utente kiosk, tramite `/etc/profile.d/kiosk-autostart.sh` (di proprietà di root: gli ospiti non possono modificarlo).
- **Browser** a schede, a tutto schermo e senza barra del titolo, in navigazione privata. Gli ospiti possono digitare qualsiasi URL. Se il browser viene chiuso o va in crash, si riapre da solo.
- **File manager minimale** (PCManFM): si apre da "Mostra nella cartella" nei download del browser. Con **Alt+Tab** si passa da una finestra all'altra; chiudendo il file manager si torna al browser.
- **Reset per inattività**: dopo N minuti senza tastiera/mouse la sessione termina, Downloads, cache e profili del browser vengono cancellati e riparte una sessione nuova. Il reset avviene anche a ogni avvio e dopo il riavvio notturno. Al contrario del vecchio cron ogni 15 minuti, **non cancella mai mentre l'ospite sta lavorando**.
- **Tastiera italiana e sistema in inglese**, non modificabili dall'ospite (nessun terminale, nessuna scorciatoia per cambiare layout).
- **Blocchi**: Ctrl+Alt+F1–F6 e Ctrl+Alt+Backspace disattivati, niente screen blanking/DPMS, tasto di accensione, sospensione e chiusura del coperchio ignorati, Ctrl+Alt+Canc mascherato.
- **Aggiornamenti automatici di sola sicurezza** e **riavvio ogni notte alle 02:00** (`/etc/cron.d/kiosk-reboot`).
- **USB in sola lettura** (regola udev + opzioni `ro,nosuid,nodev,noexec` per udisks).
- **Rete** con NetworkManager: Ethernet DHCP e Wi-Fi.
- **Firmware non-free** abilitati per massimizzare la compatibilità hardware.

### Correzione importante rispetto ai vecchi script

Nei tre script originali la regola degli aggiornamenti usava `codename=${distro_codename}`, ma dal 2021 il repository di sicurezza di Debian ha codename `<release>-security`: **la regola non trovava nulla e non installava mai aggiornamenti**. Ora usa `codename=${distro_codename}-security`.

## Gestione remota (SSH)

Con SSH attivo l'accesso è consentito **solo all'utente admin** (mai a root né all'utente kiosk). Se incolli una chiave pubblica, la password viene disattivata e si entra solo con la chiave: è la scelta consigliata.

**Creare la chiave su Windows** (PowerShell):

```powershell
ssh-keygen -t ed25519
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

Incolla la riga stampata (inizia con `ssh-ed25519`) quando lo script la chiede.

**Collegarsi** (da un PC sulla stessa rete):

```powershell
ssh admin@nomehost.local     # oppure ssh admin@<indirizzo IP>
```

L'indirizzo IP lo trovi nella tabella DHCP del router; `nomehost.local` funziona grazie ad avahi, installato insieme a SSH. Se rispondi "no" al riavvio automatico puoi anche leggerlo con `hostname -I`.

**Comandi utili sul kiosk:**

```bash
sudo kiosk-set-url https://nuovo.esempio.it   # cambia pagina iniziale e riavvia la sessione
sudo kiosk-restart-session                    # riavvia la sessione ospite
sudo nano /etc/kiosk/kiosk.conf               # browser, URL, minuti di inattività
systemd-analyze                               # tempo di boot
```

Dopo aver modificato `kiosk.conf` a mano esegui `sudo kiosk-restart-session`.

## Stampanti

La maggior parte delle stampanti di rete moderne funziona senza driver (IPP Everywhere):

```bash
sudo lpadmin -p Reception -E -v ipp://192.168.1.50/ipp/print -m everywhere
sudo lpoptions -d Reception
```

In alternativa apri l'interfaccia web di CUPS da remoto con un tunnel SSH: `ssh -L 6310:localhost:631 admin@nomehost.local`, poi `http://localhost:6310` sul tuo PC. L'auto-rilevamento delle stampanti (`cups-browsed`) è disattivato di proposito sulla rete ospiti.

## Wi-Fi

Se non l'hai impostato durante l'installazione: `sudo nmtui`, oppure `sudo nmcli device wifi connect "NOME" password "PASSWORD"`. Il profilo creato dallo script è `/etc/NetworkManager/system-connections/kiosk-wifi.nmconnection`, leggibile solo da root, con la password in chiaro. Il vecchio `/etc/network/interfaces` è salvato come `interfaces.kiosk-backup`.

## File importanti

| Percorso | A cosa serve |
|---|---|
| `/etc/kiosk/kiosk.conf` | utente, browser, URL, minuti di inattività |
| `/usr/local/lib/kiosk/session.sh` | cosa parte dentro X |
| `/usr/local/lib/kiosk/wipe.sh` | pulizia a inizio sessione |
| `/usr/local/lib/kiosk/idle-watcher.sh` | controllo inattività |
| `/usr/local/lib/kiosk/openbox-rc.xml` | finestre, scorciatoie, mouse |
| `/etc/profile.d/kiosk-autostart.sh` | avvio di X per l'utente kiosk |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | autologin |
| `/etc/X11/xorg.conf.d/` | tastiera italiana e blocchi di X |
| `/etc/chromium/policies/managed/kiosk.json` o `/usr/lib/firefox-esr/distribution/policies.json` | criteri del browser |
| `/etc/udev/rules.d/99-kiosk-usb-readonly.rules` | USB sola lettura |
| `/etc/apt/apt.conf.d/99kiosk-security-only` | aggiornamenti solo di sicurezza |
| `/etc/cron.d/kiosk-reboot` | riavvio notturno |

## Problemi comuni

- **Schermo nero dopo il boot**: guarda `/home/kiosk/.kiosk-session.log` e `/home/kiosk/.local/share/xorg/Xorg.0.log`, poi `journalctl -b`. Controlla che i firmware siano stati installati (`apt-cache policy firmware-linux`).
- **Audio assente**: `aplay -l` per vedere le schede; se è muto, `alsamixer` (F6 per scegliere la scheda, `M` per togliere il muto) e `sudo alsactl store`.
- **USB non scrivibile**: è voluto. Per disattivare il blocco rimuovi `/etc/udev/rules.d/99-kiosk-usb-readonly.rules` e `/etc/udisks2/mount_options.conf`, esegui `sudo udevadm control --reload` e riconnetti la chiavetta.
- **Nuove lingue sparite**: se hai scelto di rimuovere le lingue inutili, `localepurge` tiene solo inglese e italiano.
- **File non apribili dal file manager**: sono installati solo il browser (che apre PDF e immagini) e il file manager. Per altri formati aggiungi un visualizzatore, per esempio `sudo apt install evince`.

## Limiti da conoscere

- Il reset della sessione richiede circa 10-20 secondi di schermo nero prima che riparta il browser.
- Chi guarda un video senza toccare mouse o tastiera per N minuti viene considerato inattivo e la sessione viene resettata.
- Non è un kiosk "blindato" (nessun `--kiosk`, come da tua scelta): l'ospite può aprire schede libere. Il file manager non è confinato e mostra ciò che i permessi di Linux consentono all'utente kiosk, che non ha privilegi.
- I criteri di Chromium bloccano solo DevTools, impostazioni e `view-source`; `file://` non è bloccato.
- Chromium parte **senza** `--no-sandbox` (usava un flag poco sicuro nei vecchi script): se su qualche macchina non partisse, controlla `sysctl kernel.unprivileged_userns_clone` prima di forzarlo.
