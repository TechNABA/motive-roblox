<#
Test of Converti.bat (Windows PowerShell 5.1). Nothing reaches GitHub: every run uses a local bare repository
as a stand-in for origin, built from the current commit.

  $env:MOTIVE_TEST_FBX = "C:\path\to\a\take.fbx"
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\converti_bat_test.ps1

Prints PASS, or the failed checks, and exits with 0 or 1.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sample = $env:MOTIVE_TEST_FBX
if (-not $sample -or -not (Test-Path $sample)) { Write-Output 'MOTIVE_TEST_FBX non impostata'; exit 1 }

$root = Join-Path $env:TEMP ("converti-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null
$failures = New-Object System.Collections.Generic.List[string]
function Check($cond, $what) { if (-not $cond) { $failures.Add($what) } }

function Invoke-GitQuiet { & git.exe @args 2>$null }
function Run-Bat($clone, [string[]]$dragged) {
    $quoted = ($dragged | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $out = '' | cmd /c "`"$clone\Converti.bat`" $quoted" 2>&1
    return ($out | Out-String)
}
function Remote-Index { (Invoke-GitQuiet -C "$root\remote.git" show master:animazioni/index.json | Out-String | ConvertFrom-Json).takes.name }
function Add-Fbx($dir, $name, $offsetSeconds) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $path = Join-Path $dir $name
    Copy-Item $sample $path
    (Get-Item $path).LastWriteTime = (Get-Date).AddSeconds($offsetSeconds)
    return $path
}

try {
    Invoke-GitQuiet clone -q --bare $repo "$root\remote.git"
    Invoke-GitQuiet -C "$root\remote.git" update-ref refs/heads/master (Invoke-GitQuiet -C $repo rev-parse HEAD)
    Invoke-GitQuiet -C "$root\remote.git" symbolic-ref HEAD refs/heads/master
    Invoke-GitQuiet clone -q "$root\remote.git" "$root\a"
    Invoke-GitQuiet clone -q "$root\remote.git" "$root\b"
    $export = Join-Path $root 'Export Motive'

    # 1. drag a folder whose name has spaces: converted and published, the FBX stay where they are
    Add-Fbx $export 'Prova Uno.fbx' 0 | Out-Null
    $o = Run-Bat "$root\a" @($export)
    Check ($o -match 'Pubblicato') "1: not published`n$o"
    Check ((Remote-Index) -contains 'Prova Uno') '1: take not in the published list'
    Check (Test-Path "$export\Prova Uno.fbx") '1: the FBX was moved'

    # 2. drag the same folder again: nothing to publish
    $o = Run-Bat "$root\a" @($export)
    Check ($o -match 'niente da pubblicare') "2: republished an already converted file`n$o"

    # 3. GitHub unreachable
    Invoke-GitQuiet -C "$root\a" remote set-url origin "$root\non-esiste.git"
    $o = Run-Bat "$root\a" @($export)
    Check ($o -match 'collegarmi a GitHub') "3: no connection message`n$o"
    Invoke-GitQuiet -C "$root\a" remote set-url origin "$root\remote.git"

    # 4. push refused, then a later run publishes the pending take
    Set-Content -Path "$root\remote.git\hooks\pre-receive" -Value "#!/bin/sh`nexit 1" -Encoding ascii -NoNewline
    Add-Fbx $export 'Prova Due.fbx' 0 | Out-Null
    $o = Run-Bat "$root\a" @($export)
    Check ($o -match 'NON riuscita') "4: refused push not reported`n$o"
    Remove-Item "$root\remote.git\hooks\pre-receive"
    $o = Run-Bat "$root\a" @($export)
    Check ($o -match 'Pubblicato') "4: pending take not published`n$o"
    Check ((Remote-Index) -contains 'Prova Due') '4: pending take missing'

    # 5. two PCs publish different takes (both rewrite index.json): resolved, both listed
    Set-Content -Path "$root\remote.git\hooks\pre-receive" -Value "#!/bin/sh`nexit 1" -Encoding ascii -NoNewline
    $o = Run-Bat "$root\a" @((Add-Fbx "$root\Export A" 'Da A.fbx' 0))
    Remove-Item "$root\remote.git\hooks\pre-receive"
    $o = Run-Bat "$root\b" @((Add-Fbx "$root\Export B" 'Da B.fbx' 0))
    Check ($o -match 'Pubblicato') "5: PC B not published`n$o"
    $o = Run-Bat "$root\a" @()
    Check ($o -match 'Pubblicato') "5: PC A not published after B`n$o"
    $names = Remote-Index
    Check (($names -contains 'Da A') -and ($names -contains 'Da B')) "5: list misses a take: $names"

    # 6. a removed take does not come back, not even from the other PC without the local record
    Remove-Item "$root\a\animazioni\Prova_Uno.json"
    $o = Run-Bat "$root\a" @()
    Check (-not ((Remote-Index) -contains 'Prova Uno')) "6: removal not published`n$o"
    $o = Run-Bat "$root\b" @($export)
    Check (-not ((Remote-Index) -contains 'Prova Uno')) "6: removed take came back from PC B`n$o"

    # 7. Converti.bat updated on GitHub while a run is in progress: the run still completes
    $bat = Get-Content "$root\b\Converti.bat" -Raw
    Set-Content -Path "$root\b\Converti.bat" -Value ("rem riga aggiunta`r`n" * 40 + $bat) -NoNewline -Encoding ascii
    Invoke-GitQuiet -C "$root\b" commit -qam 'Aggiorna Converti.bat'
    Invoke-GitQuiet -C "$root\b" push -q
    $o = Run-Bat "$root\a" @((Add-Fbx "$root\Export C" 'Dopo Aggiornamento.fbx' 0))
    Check ($o -match 'Pubblicato') "7: run broken by the self-update`n$o"
    Check ((Remote-Index) -contains 'Dopo Aggiornamento') '7: take missing after the self-update'

    # 8. a PC without a Git identity: clear message, nothing half-published
    $env:GIT_CONFIG_GLOBAL = "$root\vuoto.gitconfig"
    Set-Content "$root\vuoto.gitconfig" "[user]`n`tuseConfigOnly = true" -Encoding ascii
    $o = Run-Bat "$root\a" @((Add-Fbx "$root\Export D" 'Senza Nome.fbx' 0))
    Remove-Item Env:GIT_CONFIG_GLOBAL
    Check ($o -match 'git config --global user.name') "8: no identity message`n$o"
    Check (-not ((Remote-Index) -contains 'Senza Nome')) '8: published without a commit'
}
catch {
    $failures.Add("error: $_")
}
finally {
    Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Output 'PASS'; exit 0 }
Write-Output "FAIL`n$($failures -join "`n")"
exit 1
