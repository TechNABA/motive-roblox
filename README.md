# motive-roblox

Porta le animazioni registrate con **OptiTrack Motive** dentro **Roblox Studio**, su qualsiasi avatar R15, pronte da
guardare e modificare nell'Animation Editor.

- **Docente**: trascina gli export di Motive su `Converti.bat` e manda agli studenti il pacchetto `.zip` che ne esce.
- **Studenti**: installano una volta il plugin e aprono il pacchetto dentro Studio. Guida: [GUIDA-STUDENTI.md](GUIDA-STUDENTI.md) (in inglese: [STUDENT-GUIDE.md](STUDENT-GUIDE.md)).

## Come funziona

```
Motive (FBX)  ->  Converti.bat  ->  Motive_<sessione>.zip  ->  (mail, Classroom...)  ->  plugin in Studio  ->  Animation Editor
```

1. Il **convertitore** (`converter/`, Python senza dipendenze) legge l'FBX, controlla lo scheletro e trasferisce il
   movimento su un rig R15 di riferimento (R15 classico). Lo spostamento dell'attore nello spazio viene mantenuto e
   scalato sulla sua gamba, cosi' attori di altezze diverse danno lo stesso risultato.
2. Le take finiscono in un **pacchetto `.zip`**: un file `.json` per take e `pacchetto.json` con l'elenco.
3. Il **plugin** (`plugin/MotiveAnimazioni.lua`) apre il pacchetto scelto dallo studente, e quando lo studente clicca
   una take la adatta agli avatar selezionati (R15 classico o R15 Plus, qualsiasi corpo) e la salva dove la trova
   l'Animation Editor (`ServerStorage > RBX_ANIMSAVES`, collegata all'avatar con `AnimSaves`). Non scarica niente da
   internet.

## Creare un pacchetto (docente, Windows)

Una volta sola: scarica il repository (`git clone https://github.com/TechNABA/motive-roblox`, o lo zip del codice dalla
release) su un PC con [Python](https://www.python.org) 3.8 o piu' recente. Comodo: click destro su `Converti.bat` >
**Crea collegamento**, e sposta il collegamento sul desktop.

Ogni volta:

1. In Motive esporta le take come **FBX binario** dello scheletro, con **Y up** (le impostazioni usate finora).
2. **Trascina la cartella degli export** (o uno o piu' file `.fbx`) su `Converti.bat` o sul suo collegamento. Della
   cartella legge solo gli FBX che contiene, non le sottocartelle; gli FBX non vengono toccati.
3. Si apre la cartella `pacchetti` con `Motive_<nome della cartella>.zip` (o `Motive_<data>_<ora>.zip` se hai trascinato
   piu' file): mandalo agli studenti cosi' com'e', senza estrarlo.

Le take con problemi vengono elencate con il motivo e restano fuori dal pacchetto; le altre ci sono. Ritrascinare la
stessa cartella rifa' il pacchetto da capo.

Nei nomi delle cartelle da trascinare evita i caratteri `&` e `^`: Windows spezza il percorso prima che lo script parta.

### Cosa controlla il convertitore

| Messaggio | Cosa fare |
| --- | --- |
| `non e' un FBX binario` / `danneggiato` | Riesporta da Motive in formato FBX binario. |
| `ossa mancanti: ...` / `osso Hips non trovato` | Lo scheletro non e' quello atteso (nomi tipo Hips, Spine4, LeftArm...): usa lo stesso tipo di scheletro in Motive. |
| `piu' scheletri` | Esporta un attore per file. |
| `non ha l'asse Y verso l'alto` / `non e' Y up` | Esporta con Y up. |
| `l'attore non guarda verso +Z` | La posa di riposo dell'export e' ruotata: controlla le impostazioni di export. |
| `Pre/PostRotation`, `ordine di rotazione`, `scalato`, `RotationPivot`... | Impostazioni di export diverse da quelle previste: riesporta con quelle standard di Motive. |
| `stesso nome di ...` | Due FBX diventano lo stesso nome di take: rinomina uno dei due. |

Opzioni (da riga di comando): `--sul-posto` toglie lo spostamento orizzontale; `--out=CARTELLA` cambia dove finisce il
pacchetto.

## Il plugin per gli studenti

Il file del plugin per Studio e' nella [release](https://github.com/TechNABA/motive-roblox/releases/latest):
`MotiveAnimazioni.rbxmx`.

Ogni studente trascina `MotiveAnimazioni.rbxmx` in Studio, click destro sullo script > **Save as Local Plugin**, poi
cancella lo script dalla scena (istruzioni nella guida studenti, `GUIDA-STUDENTI.md` e `STUDENT-GUIDE.md`).

**Creator Store**: il plugin e' caricato dall'account TechNABA (asset 91142360787208), ma il 2026-11-20 la moderazione
non l'ha distribuito ("potrebbe violare le Norme comunitarie", senza motivo). Finche' non e' pubblicato, gli studenti lo
installano dal file della release. Quando lo store lo distribuisce, il link della pagina va al punto 1 delle guide
studenti: da li' lo installano con un clic e Studio lo aggiorna da solo quando ripubblichi.

Cosa fa il pannello: **Apri pacchetto...** accetta il `.zip` (anche se ricompresso da Windows o macOS) e, in
alternativa, i file `.json` delle take (Safari su Mac a volte estrae lo zip da solo). Con piu' avatar selezionati la
take viene applicata a ciascuno; se un avatar ha gia' quella take non la aggiunge di nuovo. Una barra mostra
l'avanzamento e i bottoni restano disattivati finche' ha finito.

## Limiti

- Le animazioni girano nell'Animation Editor e nella viewport. Per usarle in un gioco vanno pubblicate dall'Animation
  Editor; in gioco il personaggio non segue lo spostamento dell'attore.
- Dita e punte dei piedi non ci sono: un avatar R15 ha solo mano e piede interi. Le 5 ossa della schiena diventano
  UpperTorso, collo e testa diventano Head.
- Ogni frame e' un keyframe (30 al secondo). Nell'Animation Editor: **... > Optimize Keyframes** per sfoltirli.
- Il pannello non ricorda i pacchetti aperti: chiuso Studio, il pacchetto si riapre.

## Sviluppo

- Test del convertitore: `MOTIVE_TEST_FBX=<una take .fbx> python -m unittest discover -s tests`
  (senza la variabile, i test che leggono un FBX vero vengono saltati).
- Test di `Converti.bat` (Windows): `MOTIVE_TEST_FBX=<una take .fbx>`, poi
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\converti_bat_test.ps1`. Stampa PASS.
- Test del plugin in Studio: istruzioni in testa a `tests/plugin_test.luau` (pacchetto in quattro varianti di zip e come
  .json, R15 classico e R15 Plus creati al volo, confronto con Motive, piu' avatar, doppioni, errori; stampa PASS).
- File del plugin per la release: `python tools/build_plugin.py` -> `build/MotiveAnimazioni.rbxmx`.
- Codici d'uscita del convertitore: 0 tutto convertito, 10 alcuni file rifiutati (il pacchetto contiene gli altri),
  2 nessun pacchetto.
- Formato di una take (`<take>.json` nel pacchetto): `frames` frame a `fps` 30; per ogni frame `root` (3 numeri:
  spostamento del bacino in stud sul rig R15 classico) e `rot` (15 quaternioni x, y, z, w: rotazione locale di ogni
  parte nell'ordine di `parts`, con genitori in `parents`).
