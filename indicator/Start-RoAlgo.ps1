$ErrorActionPreference = 'Stop'
$roalgoDirectory = $PSScriptRoot
$roalgoExisting = $null
try { $roalgoExisting = Invoke-RestMethod -Uri 'http://127.0.0.1:47622/health' -TimeoutSec 2 } catch {}
if ($roalgoExisting) {
    if ($roalgoExisting.app -ne 'RoAlgo indicator') { throw 'Port 47622 belongs to a different service.' }
    Write-Output 'RoAlgo data bridge is already running. Open RoAlgo in Roblox Studio.'
    exit 0
}
$roalgoNode = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path -LiteralPath $roalgoNode)) { $roalgoNode = (Get-Command node -ErrorAction Stop).Source }
$roalgoProcess = Start-Process -FilePath $roalgoNode -ArgumentList 'bridge.mjs' -WorkingDirectory $roalgoDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $roalgoDirectory 'bridge.stdout.log') -RedirectStandardError (Join-Path $roalgoDirectory 'bridge.stderr.log') -PassThru
Write-Output ('Started local RoAlgo data bridge, process ' + $roalgoProcess.Id + '. Open RoAlgo in Roblox Studio.')
