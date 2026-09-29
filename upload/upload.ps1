# Voidwatch upload script for Windows. It sends what the module writes and brings back the replies. MIT licence.
#   powershell -ExecutionPolicy Bypass -File upload.ps1 "<the voidwatch folder in the client's write directory>"
# The module shows the exact folder in a game message.
param([string]$Dir = '')
$Home_ = Join-Path $env:LOCALAPPDATA 'Voidwatch'

# Without a folder: watch every client on this computer. The usual places are searched every 30 s, plus the folders
# listed in folders.txt next to this script (setup adds the one you drop on it). Each client gets its own hidden worker.
if (-not $Dir) {
  New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
  while ($true) {
    $found = @(Get-ChildItem (Join-Path $env:APPDATA 'OTClientV8') -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'voidwatch' } | Where-Object { Test-Path (Join-Path $_ 'outbox') })
    $list = Join-Path $Home_ 'folders.txt'
    if (Test-Path $list) { $found += Get-Content $list | Where-Object { $_ -and (Test-Path $_) } }
    foreach ($d in ($found | Sort-Object -Unique)) {
      $pidFile = Join-Path $d '.pid'
      $alive = $false
      if (Test-Path $pidFile) { $alive = [bool](Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue) }
      if (-not $alive) {
        $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $d)
        Set-Content -Path $pidFile -Value $p.Id
      }
    }
    Start-Sleep -Seconds 30
  }
}
$Api = if ($env:VOIDWATCH_API) { $env:VOIDWATCH_API } else { 'https://voidwatch.xyz/api/v1' }
$Out = Join-Path $Dir 'outbox'; $In = Join-Path $Dir 'inbox'; $TokenFile = Join-Path $Dir '.token'
New-Item -ItemType Directory -Force -Path $In | Out-Null
$lastCapture = [datetime]::MinValue; $lastMinimap = [datetime]::MinValue
$lastStatus = [datetime]::MinValue; $minimapCheck = [datetime]::MinValue
$statusEvery = 30; $minimapOn = $true

function Headers { @{ Authorization = 'Bearer ' + (Get-Content $TokenFile -Raw).Trim() } }

function Send-Status {
  $reply = Invoke-RestMethod -Method Post -Uri "$Api/status" -Headers (Headers) -ContentType 'application/json' -InFile "$Out\status.json" -TimeoutSec 10
  $reply | ConvertTo-Json -Depth 5 | Set-Content "$In\reply.json"
  '{"paired":true}' | Set-Content "$In\pair.json"
  $script:statusEvery = [int]$reply.statusEvery
  $script:minimapOn = $reply.settings.minimap -ne $false
  $script:lastStatus = Get-Date
  if ($reply.commands -gt 0) {
    Invoke-RestMethod -Uri "$Api/commands" -Headers (Headers) -TimeoutSec 10 | ConvertTo-Json -Depth 5 -AsArray | Set-Content "$In\commands.json"
  }
}

while ($true) {
  try {
    if (-not (Test-Path $TokenFile)) {
      if (Test-Path "$Out\pair-request.json") {
        $r = Invoke-RestMethod -Method Post -Uri "$Api/pair" -ContentType 'application/json' -InFile "$Out\pair-request.json" -TimeoutSec 10
        Set-Content -Path $TokenFile -Value $r.token -NoNewline
        @{ code = $r.code; url = $r.url; expiresAt = $r.expiresAt } | ConvertTo-Json | Set-Content "$In\pair.json"
      }
      Start-Sleep -Seconds 1
      continue
    }
    if ((Test-Path "$Out\status.json") -and ((Get-Date) - $lastStatus).TotalSeconds -ge $statusEvery) { Send-Status }
    $shot = Get-Item "$Out\capture.png" -ErrorAction SilentlyContinue
    if ($shot -and $shot.LastWriteTime -ne $lastCapture) {
      Invoke-RestMethod -Method Post -Uri "$Api/capture" -Headers (Headers) -ContentType 'image/png' -InFile $shot.FullName -TimeoutSec 20 | Out-Null
      $lastCapture = $shot.LastWriteTime
    }
    if (Test-Path "$Out\results.json") {
      foreach ($r in (Get-Content "$Out\results.json" -Raw | ConvertFrom-Json)) {
        $body = @{ ok = $r.ok; message = $r.message } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri "$Api/commands/$($r.id)/result" -Headers (Headers) -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
      }
      Remove-Item "$Out\results.json"
    }
    # the client's own minimap, one folder up; it changes slowly, so look at it once a minute
    if ($minimapOn -and ((Get-Date) - $minimapCheck).TotalSeconds -ge 60) {
      $minimapCheck = Get-Date
      $map = Get-ChildItem (Join-Path $Dir '..') -Filter 'minimap*.otmm' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($map -and $map.LastWriteTime -ne $lastMinimap) {
        Invoke-RestMethod -Method Post -Uri "$Api/minimap" -Headers (Headers) -ContentType 'application/octet-stream' -InFile $map.FullName -TimeoutSec 60 | Out-Null
        $lastMinimap = $map.LastWriteTime
      }
    }
    if ($statusEvery -le 2) {
      Start-Sleep -Seconds 1
    } else {
      # wait until someone opens the character, an alert fires or a command arrives; returns at once when that happens
      $w = Invoke-RestMethod -Uri "$Api/wait?timeout=25" -Headers (Headers) -TimeoutSec 30
      if ($w.wake) { $lastStatus = [datetime]::MinValue }
    }
  } catch { Write-Host (Get-Date -Format 'HH:mm:ss') $_.Exception.Message; Start-Sleep -Seconds 2 }
}
