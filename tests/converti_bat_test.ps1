<#
Test of Converti.bat (Windows PowerShell 5.1), run on a copy of the repository in %TEMP%.

  $env:MOTIVE_TEST_FBX = "C:\path\to\a\take.fbx"
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\converti_bat_test.ps1

Prints PASS, or the failed checks, and exits with 0 or 1.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sample = $env:MOTIVE_TEST_FBX
if (-not $sample -or -not (Test-Path $sample)) { Write-Output 'MOTIVE_TEST_FBX non impostata'; exit 1 }

$root = Join-Path $env:TEMP ("converti-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$failures = New-Object System.Collections.Generic.List[string]
function Check($cond, $what) { if (-not $cond) { $failures.Add($what) } }

function Run-Bat([string[]]$dragged) {
    $quoted = ($dragged | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $out = '' | cmd /c "`"$root\repo\Converti.bat`" $quoted" 2>&1
    return ($out | Out-String)
}
function Packages { @(Get-ChildItem "$root\repo\pacchetti" -Filter *.zip -ErrorAction SilentlyContinue | ForEach-Object Name) }

try {
    New-Item -ItemType Directory "$root\repo" | Out-Null
    foreach ($item in 'Converti.bat', 'converter') { Copy-Item -Recurse (Join-Path $repo $item) "$root\repo\$item" }
    # the explorer window Converti.bat opens is not wanted during the test
    $bat = Get-Content "$root\repo\Converti.bat" -Raw
    Set-Content "$root\repo\Converti.bat" ($bat -replace 'start "" explorer', 'rem start "" explorer') -NoNewline -Encoding ascii

    # 1. double click, nothing dragged: instructions, no package
    $o = Run-Bat @()
    Check ($o -match 'Trascina') "1: no instructions`n$o"
    Check ((Packages).Count -eq 0) '1: a package was created'

    # 2. drag a folder whose name has spaces: package named after it, the FBX untouched
    $export = Join-Path $root 'Sessione 261106'
    New-Item -ItemType Directory $export | Out-Null
    Copy-Item $sample "$export\Prova Uno.fbx"
    Copy-Item $sample "$export\Prova Due.fbx"
    Set-Content "$export\rotto.fbx" 'non un fbx' -Encoding ascii
    $o = Run-Bat @($export)
    Check ($o -match 'PACCHETTO') "2: no package reported`n$o"
    Check ($o -match 'rotto.fbx') "2: broken file not reported`n$o"
    Check ((Packages) -contains 'Motive_Sessione_261106.zip') "2: package missing: $(Packages)"
    Check ((Get-ChildItem $export -Name).Count -eq 3) '2: the FBX folder was changed'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead("$root\repo\pacchetti\Motive_Sessione_261106.zip")
    $names = $zip.Entries | ForEach-Object FullName
    $zip.Dispose()
    Check (($names -contains 'pacchetto.json') -and ($names -contains 'Prova_Uno.json') -and ($names -contains 'Prova_Due.json')) "2: zip content: $names"

    # 3. only broken files: no package, clear message
    $bad = Join-Path $root 'Solo rotti'
    New-Item -ItemType Directory $bad | Out-Null
    Set-Content "$bad\x.fbx" 'non un fbx' -Encoding ascii
    $o = Run-Bat @($bad)
    Check ($o -match 'nessun pacchetto creato') "3: no message for broken files`n$o"
    Check ((Packages).Count -eq 1) '3: a package was created from broken files'

    # 4. two single files: one package named by date and time
    $o = Run-Bat @("$export\Prova Uno.fbx", "$export\Prova Due.fbx")
    Check ((Packages | Where-Object { $_ -match '^Motive_\d{8}_\d{4}\.zip$' }).Count -eq 1) "4: dated package missing: $(Packages)"
}
catch {
    $failures.Add("error: $_")
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Output 'PASS'; exit 0 }
Write-Output "FAIL`n$($failures -join "`n")"
exit 1
