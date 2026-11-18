@echo off
rem Converte gli FBX di Motive e pubblica le take per gli studenti.
rem Trascina su questo file (o su un suo collegamento) la cartella degli export di Motive, o dei file .fbx;
rem con il doppio clic usa la cartella export_motive.
setlocal

rem The update from GitHub may rewrite this very file while cmd is reading it: run from a temporary copy.
rem The call, the cleanup and the exit are on one line, which cmd reads whole before running it.
if defined MOTIVE_REPO goto avviato
set "MOTIVE_REPO=%~dp0"
set "MOTIVE_COPIA=%TEMP%\motive-converti-%RANDOM%%RANDOM%.bat"
copy /y "%~f0" "%MOTIVE_COPIA%" >nul
call "%MOTIVE_COPIA%" %* & del "%MOTIVE_COPIA%" >nul 2>&1 & exit /b
:avviato
cd /d "%MOTIVE_REPO%"

rem "where python" also finds the Windows Store stub: check that Python really runs; python.org installs "py"
set PY=python
%PY% -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>&1
if errorlevel 1 (
    set PY=py -3
    py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>&1
)
if errorlevel 1 (
    echo Python 3 non e' installato su questo PC: installalo da https://www.python.org e riprova.
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
rem takes removed by hand are recorded first, so the rebase cannot lose them in the autostash
call :registra
if errorlevel 1 goto noidentity
rem index.json and tolte.json are recomputed by the converter: on a conflict keep either side
rem (.gitattributes: merge=ours); a removal lost this way is found again from index.json
git config merge.ours.driver true
for /f %%s in ('git stash list ^| find /c /v ""') do set STASH_PRIMA=%%s
git rebase --quiet --autostash origin/master >nul 2>&1
set REBASE=%errorlevel%
for /f %%u in ('git diff --name-only --diff-filter=U ^| find /c /v ""') do set UNMERGED=%%u
if not "%UNMERGED%"=="0" set REBASE=1
if not "%REBASE%"=="0" (
    git rebase --abort >nul 2>&1
    echo.
    echo Questa cartella e GitHub hanno modifiche diverse alle stesse take.
    echo Per ripartire da GitHub, apri un terminale in questa cartella e scrivi:
    echo     git reset --hard origin/master
    echo poi trascina di nuovo gli FBX da ripubblicare.
    goto fine
)
for /f %%s in ('git stash list ^| find /c /v ""') do set STASH_DOPO=%%s
if not "%STASH_DOPO%"=="%STASH_PRIMA%" (
    echo ATTENZIONE: alcune modifiche fatte a mano in questa cartella erano in conflitto con GitHub e sono
    echo state messe da parte ^(git stash list^). Le take vengono comunque convertite e pubblicate.
)

echo.
echo Converto gli FBX...
%PY% -m converter %*
rem 0 = all converted, 10 = some files rejected (the others are published); anything else = stop
set RC=%errorlevel%
if not "%RC%"=="0" if not "%RC%"=="10" (
    echo.
    echo La conversione si e' interrotta: non pubblico niente.
    goto fine
)

call :registra
if errorlevel 1 goto noidentity
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
goto fine

rem Commit the changes in animazioni, if any. errorlevel 1 = the commit failed.
:registra
git add animazioni
git diff --cached --quiet -- animazioni
if not errorlevel 1 exit /b 0
git commit --quiet -m "Aggiorna le take" -- animazioni >nul 2>&1
exit /b %errorlevel%

:noidentity
echo.
echo Non riesco a registrare le modifiche. Se e' la prima volta su questo PC, apri un terminale e scrivi:
echo     git config --global user.name "Il tuo nome"
echo     git config --global user.email "tua@email"
echo poi rilancia Converti.bat.

:fine
echo.
pause
