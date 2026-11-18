# motive-roblox

Porta le animazioni registrate con **OptiTrack Motive** dentro **Roblox Studio**, su qualsiasi avatar R15, pronte da
guardare e modificare nell'Animation Editor.

- **Studenti**: installano una volta il plugin e scelgono le animazioni da un elenco dentro Studio. Guida:
  [GUIDA-STUDENTI.md](GUIDA-STUDENTI.md).
- **Docente**: esporta gli FBX da Motive e li pubblica con un doppio clic (sotto).

## Come funziona

```
Motive (FBX)  ->  Converti.bat  ->  animazioni/*.json su GitHub  ->  plugin in Studio  ->  Animation Editor
```

1. Il **convertitore** (`converter/`, Python senza dipendenze) legge l'FBX, controlla lo scheletro e trasferisce il
   movimento su un rig R15 di riferimento (R15 classico). Lo spostamento dell'attore nello spazio viene mantenuto e
   scalato sulla sua gamba, cosi' attori di altezze diverse danno lo stesso risultato.
2. Le take convertite stanno in `animazioni/`, con l'elenco `animazioni/index.json`, sul branch `master` di questo
   repository pubblico.
3. Il **plugin** (`plugin/MotiveAnimazioni.lua`) scarica l'elenco, e quando lo studente clicca una take la adatta al suo
   avatar (R15 classico o R15 Plus, qualsiasi corpo) e la salva dove la trova l'Animation Editor
   (`ServerStorage > RBX_ANIMSAVES`, collegata all'avatar con `AnimSaves`).

## Pubblicare nuove take (docente, Windows)

Una volta sola: clona il repository (`git clone https://github.com/TechNABA/motive-roblox`) su un PC con
[Python](https://www.python.org) e [Git](https://git-scm.com) e con accesso in scrittura al repository.

Ogni volta:

1. In Motive esporta le take come **FBX binario** dello scheletro, con **Y up** (le impostazioni usate finora).
2. Copia gli FBX nella cartella `export_motive` del repository. Gli FBX non vengono pubblicati (sono esclusi da Git).
3. Doppio clic su **`Converti.bat`**: converte, controlla e pubblica. Le take con problemi vengono elencate con il
   motivo, restano in `export_motive` e non vengono pubblicate; le altre si', e i loro FBX passano in
   `export_motive\convertiti`.
4. Gli studenti vedono le take nuove nel plugin con **Aggiorna elenco** (GitHub puo' metterci qualche minuto).

Per **togliere** una take: cancella il suo `.json` da `animazioni/`, poi doppio clic su `Converti.bat`.
Per **riconvertire** una take: riporta il suo FBX da `export_motive\convertiti` a `export_motive`, poi `Converti.bat`.

### Cosa controlla il convertitore

| Messaggio | Cosa fare |
| --- | --- |
| `non e' un FBX binario` | Riesporta da Motive in formato FBX binario. |
| `ossa mancanti: ...` / `osso Hips non trovato` | Lo scheletro non e' quello atteso (nomi tipo Hips, Spine4, LeftArm...): usa lo stesso tipo di scheletro in Motive. |
| `non ha l'asse Y verso l'alto` / `non e' Y up` | Esporta con Y up. |
| `l'attore non guarda verso +Z` | La posa di riposo dell'export e' ruotata: controlla le impostazioni di export. |
| `Pre/PostRotation` / `ordine di rotazione` | Impostazioni di export diverse da quelle previste: riesporta con quelle standard di Motive. |

Opzione: `python -m converter export_motive animazioni --sul-posto` toglie lo spostamento orizzontale (take sul posto).

## Il plugin per gli studenti

Il file del plugin per Studio e' nella [release](https://github.com/TechNABA/motive-roblox/releases/latest):
`MotiveAnimazioni.rbxmx`.

**Pubblicarlo sul Creator Store (consigliato, una volta sola, dall'account Roblox del docente):**

1. Apri Studio, trascina `MotiveAnimazioni.rbxmx` nella finestra: compare lo script `AnimazioniMotive`.
2. Click destro sullo script > **Publish as Plugin**. Nome "Animazioni Motive", distribuzione pubblica e gratuita.
3. Copia il link della pagina del plugin nella guida studenti (`GUIDA-STUDENTI.md`, punto 1).

Da quel momento gli studenti lo installano con un clic e Studio lo aggiorna da solo quando ripubblichi.

**Senza Creator Store**: ogni studente trascina `MotiveAnimazioni.rbxmx` in Studio, click destro sullo script >
**Save as Local Plugin**, poi cancella lo script dalla scena (istruzioni nella guida studenti).

**Primo utilizzo**: Studio chiede se il plugin puo' collegarsi a `raw.githubusercontent.com`. Bisogna consentire.

## Limiti

- Le animazioni girano nell'Animation Editor e nella viewport. Per usarle in un gioco vanno pubblicate dall'Animation
  Editor; in gioco il personaggio non segue lo spostamento dell'attore.
- Dita e punte dei piedi non ci sono: un avatar R15 ha solo mano e piede interi. Le 5 ossa della schiena diventano
  UpperTorso, collo e testa diventano Head.
- Ogni frame e' un keyframe (30 al secondo). Nell'Animation Editor: **... > Optimize Keyframes** per sfoltirli.

## Sviluppo

- Test del convertitore: `MOTIVE_TEST_FBX=<una take .fbx> python -m unittest discover -s tests`
  (senza la variabile, i test che leggono un FBX vero vengono saltati).
- File del plugin per la release: `python tools/build_plugin.py` -> `build/MotiveAnimazioni.rbxmx`.
- Test del plugin in Studio: istruzioni in testa a `tests/plugin_test.luau` (scarica take vere da GitHub, le
  applica a un R15 classico e a un R15 Plus creati al volo, confronta con Motive, pulisce; stampa PASS).
- Formato di una take (`animazioni/<take>.json`): `frames` frame a `fps` 30; per ogni frame `root` (3 numeri: spostamento
  del bacino in stud sul rig R15 classico) e `rot` (15 quaternioni x, y, z, w: rotazione locale di ogni parte nell'ordine
  di `parts`, con genitori in `parents`).
