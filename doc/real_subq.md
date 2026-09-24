# Real Subchannel Q ("real-subq") – design e stato del lavoro

Obiettivo: fare in modo che il lettore CD del core PSX si comporti come quello di una
PlayStation reale anche per il **Subchannel Q**. Il Q che il gioco vede (GetLocP, report
CD-DA, AutoPause, GetQ) deve essere quello **letto dal disco**, non quello ricostruito dal
core a partire dalla TOC.

Il lavoro riguarda due repository:

| Repository | Branch | Cosa cambia |
|---|---|---|
| `PSX_MiSTer` (core) | `real-subq` | `rtl/hps_ext.v`, `rtl/cd_top.vhd`, `rtl/psx_top.vhd`, `rtl/psx_mister.vhd`, `PSX.sv`, testbench in `sim/subq/` |
| `Main_MiSTer_Physical_Disc` (Main) | `real-subq` | `support/psx/psx_subq.cpp/.h` (nuovi), `support/psx/psx.cpp`, `support/physical_disc/physical_disc.cpp/.h`, `user_io.cpp`, `support.h` |

Più il tool `psx_subq_probe`, da eseguire sul MiSTer prima di tutto il resto.

---

## 1. Come funziona il sub-Q su una PSX reale

Riferimenti: psx-spx, capitoli *CDROM Drive* e *CDROM Protection - LibCrypt*.

* Ogni frame del disco (1/75 s) porta 12 byte di Q:
  * byte 0: control/ADR;
  * byte 1: traccia; byte 2: indice;
  * byte 3-5: MSF relativo; byte 6: zero; byte 7-9: MSF assoluto;
  * byte 10-11: CRC-16 (CCITT, memorizzato invertito).
* Il controller (HC05) legge il Q di **ogni** frame. Se il **CRC è errato** il frame viene
  ignorato e la posizione resta quella dell'ultimo Q valido. È esattamente il meccanismo
  su cui si basa LibCrypt: 16 bit di chiave codificati come coppie di frame con Q
  alterato e CRC sbagliato, a 03:xx e con una copia di riserva a 09:xx.
* Per la posizione il controller considera solo i 2 bit bassi di ADR (ADR=1, e anche 5).
  I frame ADR=2 (catalogo) e ADR=3 (ISRC) sono esclusi da GetlocP.
* **GetlocP (11h)** restituisce traccia, indice, MSF relativo e assoluto dell'ultimo Q valido.
  Funziona anche durante il seek e con la testina ferma (posizione fisica).
* In **Play con Report** il Q viene inoltrato ogni 10 frame. **AutoPause** usa il cambio di
  traccia visto nel Q.
* **GetQ (1Dh, adr, point)** (solo controller vC1+) legge i 10 byte di Q del **lead-in**
  per un point (01h..99h = traccia, A0/A1/A2).
  * Se il point non esiste: timeout di circa 6 s, poi INT5 (e un secondo INT5 all'avvio
    della riproduzione della traccia 1).
  * La risposta ha 10 byte di Q + `peak_lo`.

## 2. Com'è il core upstream

* Il core **sintetizza** il Q a ogni settore (`SSUB_*` in `cd_top.vhd`):
  * il Q è quello di `lastReadSector + 2`, cioè il Q è due frame avanti rispetto al dato;
  * l'ARM chiede il settore N, il gioco vede il Q del frame N+2.
* LibCrypt è emulato con una **maschera a 16 bit** presa da un `.sbi`: sui 32 frame noti a
  03:xx il Q non viene aggiornato. La copia a 09:xx non è emulata.
* GetQ risponde "comando non valido" (come un controller vC0), anche se il core dichiara
  la versione vC1 (test 19h,20h → `95/05/16 C1`).
* Osservazione dal testbench: il Q sintetizzato di una traccia 1 **dati** ha MSF
  relativo = MSF assoluto (a 00:02:00 riporta 00:02:00). Un disco reale riporta 00:00:00.
  Con il Q reale la differenza sparisce. Va confermato su console.

## 3. Architettura

```
 Lettore USB / CHD / .sub / .sbi                      FPGA (core PSX)
 ─────────────────────────────                         ───────────────
 physical_disc (ring 4096 settori,     psx_subq.cpp      hps_ext.v              cd_top.vhd
 dati 2352 + P-W 96 per settore) ──►  psx_subq_get() ─► CD_SET (0x35) ──► subq_set ──► percorso settore:
                                        │                                           Q(N+2) → nextSubdata
 user_io: richiesta settore N ──────►  on_sector(N) ─┘                              (CRC ok+ADR1: usa Q reale,
                                                                                     CRC errato: tiene l'ultimo,
                                                                                     assente: sintetizza come upstream)
                                                                                   └► cache Q 64 frame (RAM)
 psx_poll ───────────────────────────► psx_subq_poll ◄── CD_GET (0x34) ◄── richieste: ├ posizione fisica (GetlocP da fermo)
                                                                                        └ GetQ (adr, point)
```

Il principio è che **il core non perde mai la sintesi**. Quando l'ARM non ha il Q di un
frame (sorgente assente, settore non ancora letto, lettore senza subchannel) risponde
"not present" e il core fa esattamente ciò che fa oggi, maschera LibCrypt compresa.

### 3.1 Protocollo HPS ↔ core (EXT_BUS, `hps_ext.v`)

**CD_SET 0x35 (ARM → core), 9 parole a 16 bit:**

| Parola | Contenuto |
|---|---|
| 0 | comando 0x35 |
| 1 | tag[15:0] |
| 2 | {status[7:0], tag[23:16]} |
| 3..8 | byte Q 0..11, little endian (byte 0 in [7:0] della parola 3) |

* `tag` è il frame assoluto (MSF incluso il pregap di 150, lo stesso numero con cui il core
  chiede i settori), oppure `{adr, point}` per le risposte GetQ.
* Bit di `status`:
  * bit 0 `PRESENT`: il Q esiste;
  * bit 1 `CRCOK`: il CRC è valido;
  * bit 2 `LEADIN`: risposta a GetQ;
  * bit 3 `NOTFOUND`: point non trovato.
* Alla chiusura della transazione `hps_ext` genera un impulso `subq_set` di 1 clock.

**CD_GET 0x34 (core → ARM), letto da `psx_poll`:**

| Parola | Il core risponde |
|---|---|
| 0 | {getq_seq[7:0], phys_seq[7:0]}: un contatore cambia a ogni nuova richiesta |
| 1 | phys_tag[15:0] |
| 2 | {8'h00, phys_tag[23:16]} |
| 3 | {adr, point} dell'ultima GetQ |

Resta anche il vecchio effetto di CD_GET: il toggle di `heartbeat`, usato dai savestate.

**Abilitazione.** Il bit 3 di `disk_t.metadata` (bit 19 della parola 3 della TOC) si
chiama `subqExt`. Se vale 0 il core si comporta al 100% come upstream.

**Compatibilità in entrambe le direzioni:**

* Main nuovo + core upstream: il core ignora CD_SET, ignora il bit 19 e a CD_GET risponde 0.
* Main upstream + core nuovo: `subqExt` = 0, quindi comportamento upstream.

### 3.2 Core – `cd_top.vhd`

1. **Percorso settore.**
   * In `SFETCH_START`, se `subqExt=1` e parte una richiesta nuova, il core non sintetizza
     subito: si mette in attesa (`subqWait`) del Q con tag `lastReadSector+2`, che l'ARM
     invia **prima** dei dati del settore.
   * Quando il Q arriva:
     * CRC ok e (ADR & 3) = 1 → `nextSubdata <= Q reale`;
     * presente ma CRC errato o ADR 2/3 → `nextSubdata` resta invariato (ultimo Q valido,
       come il controller vero; LibCrypt funziona da solo, anche con la copia a 09:xx);
     * non presente → sintesi upstream, con maschera `.sbi` (`libcryptHit`).
   * Se il settore termina senza Q (Main vecchio o errore), si sintetizza.
   * Se il settore è ancora nel buffer dell'ARM e non parte una richiesta, il core riusa
     l'ultimo Q ricevuto (`subqLast*`).
2. **Cache Q** (64 frame, RAM 96+30 bit, indice = tag[5:0]):
   * ogni CD_SET presente viene salvato con tag completo, flag "usabile" ed epoca;
   * l'epoca cambia a ogni cambio disco e invalida la cache.
3. **Percorso posizione fisica** (GetlocP da fermo, stati `PHYSICALUPDATE_QLOOKUP/QCHECK`):
   * la nuova posizione fisica viene cercata in cache;
   * hit usabile → `subdata <= Q reale`; hit con CRC errato → posizione invariata;
   * miss → sintesi immediata, come upstream, più una richiesta all'ARM (`phys_seq/phys_tag`).
     La risposta finisce in cache e vale per i GetlocP successivi.
   * La posizione fisica gira intorno ai settori appena letti, quindi quasi sempre c'è hit.
4. **GetQ 1Dh** (solo con `subqExt=1`, altrimenti resta l'errore upstream):
   * se il disco è fermo → errore 80h;
   * altrimenti INT3; poi parametri adr/point → richiesta all'ARM (`getq_seq`);
   * attesa di almeno `GETQ_SEARCH_TIME` (~100 ms, **da misurare su console**);
   * INT2 con 10 byte di Q + `peak_lo`=0;
   * point assente → attesa fino a `GETQ_TIMEOUT` (~6 s) e poi INT5.
   * Non emulati: il secondo INT5 e la ripartenza in play della traccia 1.
   * I parametri restano nel FIFO fino alla lettura, come per Setloc e Setfilter.
5. `GETQ_SEARCH_TIME` e `GETQ_TIMEOUT` sono generic di `cd_top`, con default realistici e
   valori brevi nel testbench.
6. Correzione di contorno: l'export savestate di `positionInIndex` usava `to_unsigned` su un
   valore che può essere negativo. È stato portato a `to_signed`, coerente con il
   ripristino che usa `signed`. Stessi bit in hardware, in simulazione non va più in errore.

**Risorse aggiunte (stima):**

* 2 RAM (64×96 e 64×30) e un centinaio di registri.
* In Quartus circa 3-4 M10K, oppure MLAB. Si possono ridurre a 80 bit di dati, perché il
  core non usa i byte CRC.
* Il core PSX è già molto pieno sul DE10-nano: **la chiusura del timing in Quartus va
  verificata** (non fattibile qui).

### 3.3 Main – `psx_subq.cpp`

**Sorgenti del Q, in ordine di priorità:**

1. **Disco fisico.** Il P-W grezzo (READ CD con sub-channel 001b) viene letto insieme ai
   dati dal ring di read-ahead del fork. `physical_disc_peek_sub()` non accede mai al
   lettore, quindi non aggiunge latenza.
   * Validazione:
     * Q con CRC ok e ADR1 → accettato solo se l'MSF assoluto corrisponde al frame
       richiesto;
     * se il lettore è sistematicamente sfasato (16 conferme) l'offset viene corretto
       automaticamente;
     * Q con CRC errato → passato come "errato" solo se i frame vicini (N-1, N+1) sono
       validi e allineati. Così un frame fuori posto non può simulare un bit LibCrypt.
2. **CHD con subcode** (RW / RW_RAW): viene riconosciuta automaticamente l'interpretazione
   con CRC valido (grezza interlacciata o deinterlacciata).
3. **`.sub` CloneCD** accanto al `.cue`: 96 byte per settore, disco intero.
4. **`.sbi`:** i frame LibCrypt (anche a 09:xx) diventano Q "presenti con CRC errato". Sulle
   immagini senza subcode il risultato equivale a quello di upstream, più la copia di riserva.

**Lead-in per GetQ:**

* disco fisico: READ TOC formato 2 (full TOC).
  * I nibble ADR/CONTROL, che MMC restituisce invertiti, vengono corretti.
  * Il formato binario o BCD è rilevato confrontando A2 con la TOC.
* immagini: lead-in ricostruito dalla TOC (tracce, A0 con tipo disco 20h, A1, A2).

**Aggancio:**

* `user_io.cpp` chiama `psx_subq_on_sector(lba)` subito prima di inviare ogni settore
  (Q del frame lba+2);
* `psx_poll()` chiama `psx_subq_poll()` al posto del semplice `spi_uio_cmd(UIO_CD_GET)`;
* il setup avviene nel mount, nel cambio disco fisico e nell'unmount.

**`physical_disc` espone tre funzioni nuove:**

* `physical_disc_peek_sub()`;
* `physical_disc_subq_capable()`;
* `physical_disc_read_full_toc()`.

## 4. Cosa resta diverso da una PSX reale (anche con real-subq)

* **SCEx** (wobble fuori dall'area dati): non è leggibile da un lettore PC. Il core risponde
  sempre "licenziato".
* **Test 19h,04h/05h** (contatori SCEx): restano fittizi.
* **Errori di lettura:** il settore arriva azzerato, i retry del controller non sono emulati.
* **Tempi:** meccanica emulata dal core, latenza reale del lettore USB.
* **GetQ con point assente:** il secondo INT5 e il play della traccia 1 non sono emulati.
* **Reset 1Ch:** il core lo tratta come comando non valido; psx-spx lo descrive come reset
  del controller. Non riguarda il sub-Q, ma va nella lista delle cose da allineare.
* **Qualità del Q fisico:** dipende dal lettore. Alcuni lettori ricalcolano o interpolano
  il Q: il probe serve a scartarli.

## 5. Verifiche fatte

| Verifica | Esito |
|---|---|
| `psx_subq_probe`: compilazione ARMv7 statica, test unitari CRC-16 / decodifica P-W | ok |
| `hps_ext.v`: simulazione Icarus (`sim/subq/tb_hps_ext.v`), CD_GET, CD_SET, transazioni troncate, altri comandi | ok, tutti i test passano |
| `cd_top.vhd`: sintesi Yosys+GHDL (`proc; check -assert`): nessun driver multiplo, RAM inferite | ok |
| Elaborazione GHDL di `psx_mister` → `psx_top` → `cd_top` con i nuovi porti (GPU/SPU-RAM come stub) | ok |
| `cd_top.vhd`: testbench GHDL (`sim/subq/tb_subq.vhd`) | vedi sotto |
| Main: build ARM completa (`bin/MiSTer`) | ok, nessun warning nuovo |

**Casi coperti dal testbench `tb_subq`** (disco modello con Q reale):

1. Lettura con GetlocP a ogni INT1: i frame LibCrypt con CRC errato non compaiono mai e resta
   la posizione precedente (14104 due volte, 14109 due volte).
2. Il frame ADR=2 viene ignorato.
3. Il frame con indice 02 passa (prova del passthrough).
4. Il frame senza Q viene sintetizzato.
5. GetlocP in pausa: servito dalla cache Q reale.
6. GetQ A2: INT3, poi INT2 con i byte corretti.
7. GetQ con point assente: INT5 dopo il timeout.
8. Seek in un'area mai letta: prima sintetizzato, poi reale dopo la risposta dell'ARM.

Lanciare con `sim/subq/run_tb_subq.sh` (servono GHDL e Icarus nel PATH).

**Da fare:**

1. Sintesi Quartus e chiusura del timing.
2. `psx_subq_probe` su 2-3 lettori con giochi LibCrypt PAL originali e il relativo `.sbi`.
3. Test su console reale per tarare `GETQ_SEARCH_TIME` e confermare la questione dell'MSF
   relativo sulla traccia 1.
4. Test di gioco:
   * LibCrypt PAL da disco fisico **senza** `sbi.zip` (es. MediEvil, Ape Escape, CTR PAL);
   * un gioco con CD-DA e indici;
   * un gioco multi-disco (cambio disco);
   * savestate durante la lettura.
