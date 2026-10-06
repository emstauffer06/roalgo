$ErrorActionPreference = 'Stop'
$roalgoMarketDirectory = $PSScriptRoot
$roalgoMarketExisting = $null
try { $roalgoMarketExisting = Invoke-RestMethod -Uri 'http://127.0.0.1:47624/health' -TimeoutSec 2 } catch {}
if ($roalgoMarketExisting) {
    if ($roalgoMarketExisting.ok -ne $true -or $roalgoMarketExisting.app -ne 'RoAlgo Market Lab' -or $roalgoMarketExisting.schemaVersion -ne 3) { throw 'Port 47624 belongs to a different or unhealthy service.' }
    if ([System.IO.Path]::GetFullPath($roalgoMarketExisting.root) -ne [System.IO.Path]::GetFullPath($roalgoMarketDirectory)) { throw 'Port 47624 serves another Market Lab workspace.' }
    Write-Output 'RoAlgo Market Lab bridge is already running. Restart its process after changing bridge.mjs; source modules are served from the current files.'
    exit 0
}
$roalgoMarketNode = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path -LiteralPath $roalgoMarketNode)) { $roalgoMarketNode = (Get-Command node -ErrorAction Stop).Source }
$roalgoMarketProcess = Start-Process -FilePath $roalgoMarketNode -ArgumentList 'bridge.mjs' -WorkingDirectory $roalgoMarketDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $roalgoMarketDirectory 'bridge.stdout.log') -RedirectStandardError (Join-Path $roalgoMarketDirectory 'bridge.stderr.log') -PassThru
$roalgoMarketReady = $false
for ($roalgoMarketAttempt=0; $roalgoMarketAttempt -lt 20; $roalgoMarketAttempt++) {
    Start-Sleep -Milliseconds 100
    if ($roalgoMarketProcess.HasExited) { throw 'RoAlgo Market Lab bridge exited; inspect bridge.stderr.log.' }
    try { $roalgoMarketHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:47624/health' -TimeoutSec 1 } catch { continue }
    if ($roalgoMarketHealth.ok -ne $true -or $roalgoMarketHealth.app -ne 'RoAlgo Market Lab' -or $roalgoMarketHealth.schemaVersion -ne 3) { throw 'Port 47624 reported an incompatible or unhealthy service after startup.' }
    if ([System.IO.Path]::GetFullPath($roalgoMarketHealth.root) -ne [System.IO.Path]::GetFullPath($roalgoMarketDirectory)) { throw 'Port 47624 serves another Market Lab workspace after startup.' }
    $roalgoMarketReady=$true
    break
}
if (-not $roalgoMarketReady) { throw 'RoAlgo Market Lab bridge did not report ready; inspect bridge.stderr.log.' }
Write-Output ('RoAlgo Market Lab bridge ready at http://127.0.0.1:47624, process ' + $roalgoMarketProcess.Id + '. Open RoAlgo in Studio Edit mode.')
