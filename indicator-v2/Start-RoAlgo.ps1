$ErrorActionPreference = 'Stop'
$roalgoResearchDirectory = $PSScriptRoot
$roalgoResearchExisting = $null
try { $roalgoResearchExisting = Invoke-RestMethod -Uri 'http://127.0.0.1:47623/health' -TimeoutSec 2 } catch {}
if ($roalgoResearchExisting) {
    if ($roalgoResearchExisting.app -ne 'RoAlgo Research' -or $roalgoResearchExisting.schemaVersion -ne 2) { throw 'Port 47623 belongs to a different service.' }
    if ([System.IO.Path]::GetFullPath($roalgoResearchExisting.root) -ne [System.IO.Path]::GetFullPath($roalgoResearchDirectory)) { throw 'Port 47623 serves another research workspace.' }
    Write-Output 'RoAlgo Research bridge is already running. Restart its process after changing bridge.mjs; source modules are served from the current files.'
    exit 0
}
$roalgoResearchNode = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path -LiteralPath $roalgoResearchNode)) { $roalgoResearchNode = (Get-Command node -ErrorAction Stop).Source }
$roalgoResearchProcess = Start-Process -FilePath $roalgoResearchNode -ArgumentList 'bridge.mjs' -WorkingDirectory $roalgoResearchDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $roalgoResearchDirectory 'bridge.stdout.log') -RedirectStandardError (Join-Path $roalgoResearchDirectory 'bridge.stderr.log') -PassThru
$roalgoResearchReady = $false
for ($roalgoResearchAttempt=0; $roalgoResearchAttempt -lt 20; $roalgoResearchAttempt++) {
    Start-Sleep -Milliseconds 100
    if ($roalgoResearchProcess.HasExited) { throw 'RoAlgo Research bridge exited; inspect bridge.stderr.log.' }
    try { $roalgoResearchHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:47623/health' -TimeoutSec 1 } catch { continue }
    if ($roalgoResearchHealth.app -eq 'RoAlgo Research' -and $roalgoResearchHealth.schemaVersion -eq 2) { $roalgoResearchReady=$true; break }
}
if (-not $roalgoResearchReady) { throw 'RoAlgo Research bridge did not report ready; inspect bridge.stderr.log.' }
Write-Output ('RoAlgo Research bridge ready at http://127.0.0.1:47623, process ' + $roalgoResearchProcess.Id + '. Open RoAlgo in Studio Edit mode.')
