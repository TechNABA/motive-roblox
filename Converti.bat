@echo off
rem Converte gli FBX di Motive in un pacchetto .zip da mandare agli studenti.
rem Trascina su questo file (o su un suo collegamento) la cartella degli export di Motive, o dei file .fbx.
setlocal
cd /d "%~dp0"

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

%PY% -m converter %*
rem 0 = all converted, 10 = some files rejected (the package holds the others); anything else = no package
set RC=%errorlevel%
if not "%RC%"=="0" if not "%RC%"=="10" goto fine
echo.
echo Il pacchetto e' nella cartella "pacchetti" che si sta aprendo: mandalo agli studenti cosi' com'e'.
start "" explorer "%~dp0pacchetti"

:fine
echo.
pause
