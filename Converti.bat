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
git pull --ff-only --quiet
if errorlevel 1 (
    echo Non riesco ad aggiornare la cartella da GitHub: controlla la connessione e riprova.
    goto fine
)

echo.
echo Converto gli FBX di export_motive...
python -m converter export_motive animazioni
if errorlevel 2 goto fine

git add animazioni
git diff --cached --quiet
if not errorlevel 1 (
    echo.
    echo Nessuna take nuova o cambiata: niente da pubblicare.
    goto fine
)
git commit --quiet -m "Aggiorna le take"
git push --quiet
if errorlevel 1 (
    echo.
    echo Pubblicazione NON riuscita: controlla la connessione e l'accesso a GitHub, poi riprova.
    goto fine
)
echo.
echo Pubblicato. Gli studenti vedono le take nuove con "Aggiorna elenco" nel plugin (entro qualche minuto).

:fine
echo.
pause
