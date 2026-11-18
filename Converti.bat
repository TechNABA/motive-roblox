@echo off
rem Converte gli FBX di Motive in export_motive e pubblica le take per gli studenti.
setlocal
cd /d "%~dp0"

where python >nul 2>&1
if errorlevel 1 (
    echo Python non e' installato su questo PC: installalo da https://www.python.org e riprova.
    goto fine
)
where git >nul 2>&1
if errorlevel 1 (
    echo Git non e' installato su questo PC: installalo da https://git-scm.com e riprova.
    goto fine
)
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%b
if not "%BRANCH%"=="master" (
    echo Questa cartella e' sul branch "%BRANCH%", non su master: niente da pubblicare da qui.
    goto fine
)

echo Aggiorno la cartella da GitHub...
git fetch --quiet origin 2>nul
if errorlevel 1 (
    echo Non riesco a collegarmi a GitHub: controlla la connessione e riprova.
    goto fine
)
git rebase --quiet --autostash origin/master >nul 2>&1
if errorlevel 1 (
    git rebase --abort >nul 2>&1
    echo.
    echo Questa cartella e GitHub hanno modifiche diverse alle stesse take.
    echo Per ripartire da GitHub, apri un terminale in questa cartella e scrivi:
    echo     git reset --hard origin/master
    echo poi rimetti in export_motive gli FBX da ripubblicare ^(sono in export_motive\convertiti^) e rilancia.
    goto fine
)

echo.
echo Converto gli FBX di export_motive...
python -m converter export_motive animazioni
if errorlevel 2 goto fine

git add animazioni
git diff --cached --quiet
if errorlevel 1 (
    git commit --quiet -m "Aggiorna le take"
    if errorlevel 1 (
        echo.
        echo Non riesco a registrare le modifiche. Se e' la prima volta su questo PC, apri un terminale e scrivi:
        echo     git config --global user.name "Il tuo nome"
        echo     git config --global user.email "tua@email"
        echo poi rilancia Converti.bat.
        goto fine
    )
)
set AHEAD=0
for /f %%n in ('git rev-list --count origin/master..HEAD') do set AHEAD=%%n
if "%AHEAD%"=="0" (
    echo.
    echo Nessuna take nuova o cambiata: niente da pubblicare.
    goto fine
)
git push --quiet origin master 2>nul
if errorlevel 1 (
    echo.
    echo Pubblicazione NON riuscita: controlla la connessione e l'accesso a GitHub.
    echo Le take sono pronte: rilancia Converti.bat e verranno pubblicate.
    goto fine
)
echo.
echo Pubblicato. Gli studenti vedono le take nuove con "Aggiorna elenco" nel plugin (entro qualche minuto).

:fine
echo.
pause
