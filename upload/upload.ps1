# Voidwatch upload script for Windows. It sends what the module writes and brings back the replies. MIT licence.
#   powershell -ExecutionPolicy Bypass -File upload.ps1                        watch every client
#   powershell -ExecutionPolicy Bypass -File upload.ps1 "<voidwatch folder>"   watch one client
# The module shows the voidwatch folder in a game message. Every character has its own folder inside it, and its own
# hidden worker.
param([string]$Dir = '', [switch]$Worker)
$Home_ = Join-Path $env:LOCALAPPDATA 'Voidwatch'

if (-not $Worker) {
  while ($true) {
    if ($Dir) {
      $found = @($Dir)
    } else {
      $found = @(Get-ChildItem (Join-Path $env:APPDATA 'OTClientV8') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'voidwatch' } | Where-Object { Test-Path $_ })
      $list = Join-Path $Home_ 'folders.txt'
      if (Test-Path $list) { $found += Get-Content $list | Where-Object { $_ -and (Test-Path $_) } }
    }
    foreach ($d in ($found | Sort-Object -Unique)) {
      $chars = Get-ChildItem $d -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'outbox') }
      foreach ($c in $chars) {
        $pidFile = Join-Path $c.FullName '.pid'
        $alive = $false
        if (Test-Path $pidFile) { $alive = [bool](Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue) }
        if (-not $alive) {
          $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Worker', '-Dir', "`"$($c.FullName)`"")
          Set-Content -Path $pidFile -Value $p.Id
        }
      }
    }
    Start-Sleep -Seconds 30
  }
}

$Api = if ($env:VOIDWATCH_API) { $env:VOIDWATCH_API } else { 'https://voidwatch.xyz/api/v1' }
$Dir = $Dir.TrimEnd('\', '/')
$Out = Join-Path $Dir 'outbox'; $In = Join-Path $Dir 'inbox'; $TokenFile = Join-Path $Dir '.token'
$Parent = Split-Path $Dir; $SentMap = Join-Path $Parent '.minimap-sent'
New-Item -ItemType Directory -Force -Path $In | Out-Null
$lastSent = $null; $lastCapture = $null; $minimapCheck = [datetime]::MinValue
$statusEvery = 30; $minimapOn = $true; $refused = 0; $wake = $false; $said = ''

# one line per change of state, never the token or the code
function Note($text) {
  if ($text -eq $script:said) { return }
  $script:said = $text
  $log = Join-Path $Dir 'upload.log'
  if ((Test-Path $log) -and (Get-Item $log).Length -gt 100000) { Move-Item -Force $log "$log.1" }
  Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $text)
}

# one call to the API: the HTTP status (0 without a connection) and the answer
function Call($method, $path, $file, $type, $timeout) {
  $a = @{ Method = $method; Uri = "$Api$path"; TimeoutSec = $timeout; UseBasicParsing = $true; Headers = @{} }
  if (Test-Path $TokenFile) { $a.Headers.Authorization = 'Bearer ' + (Get-Content $TokenFile -Raw).Trim() }
  if ($file) { $a.InFile = $file; $a.ContentType = $type }
  try {
    $r = Invoke-WebRequest @a
    return @{ code = [int]$r.StatusCode; body = [string]$r.Content }
  } catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    return @{ code = $code; body = [string]$_.ErrorDetails.Message }
  }
}

# the module reads these files, so they are written whole, as UTF-8 without a byte order mark
function Put($path, $text) {
  [IO.File]::WriteAllText("$path.tmp", $text)
  Move-Item -Force "$path.tmp" $path
}

# the client writes a screenshot on the next frame: send it only once its first and last bytes are there
function Whole-Png($path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 20) { return $false }
  $head = [Text.Encoding]::ASCII.GetString($b, 1, 3)
  $tail = [Text.Encoding]::ASCII.GetString($b, $b.Length - 8, 4)
  return $b[0] -eq 0x89 -and $head -eq 'PNG' -and $tail -eq 'IEND'
}

function Field($text, $name) { if ("$text" -match ('"' + $name + '":\s*([0-9a-z]+)')) { $matches[1] } }

function Unpair($why) {
  Note "$why, asking for a new code"
  Remove-Item -Force -ErrorAction SilentlyContinue $TokenFile, "$In\pair.json", "$In\reply.json"
  $script:refused = 0
}

function Revoked($r) { return $r.code -eq 401 -and "$($r.body)" -match '"detail":"revoked client"' }

function On-Refused {
  $script:refused++
  $pair = Get-Content "$In\pair.json" -Raw -ErrorAction SilentlyContinue
  if ("$pair" -match '"paired":true') {
    if ($script:refused -ge 3) { Unpair 'the website refused this client' }
  } else {
    $expires = [long](Field $pair 'expiresAt')
    if (-not $expires -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -gt $expires) { Unpair 'the code expired' }
    else { Note 'waiting until the code is used' }
  }
}

while (Test-Path $Dir) {
  try {
    $now = Get-Date
    if (-not (Test-Path $TokenFile)) {
      if (Test-Path "$Out\pair-request.json") {
        $r = Call 'Post' '/pair' "$Out\pair-request.json" 'application/json' 10
        if ($r.code -eq 200 -and $r.body -match '"token":"([^"]+)"') {
          [IO.File]::WriteAllText($TokenFile, $matches[1])
          Put "$In\pair.json" ($r.body -replace '"token":"[^"]*",?', '')
          Note 'got a pairing code'
        } else {
          Note "pairing failed: HTTP $($r.code)"
          Start-Sleep -Seconds 30
        }
      }
      Start-Sleep -Seconds 1
      continue
    }

    $status = Get-Item "$Out\status.json" -ErrorAction SilentlyContinue
    $age = if ($status) { ($now - $status.LastWriteTime).TotalSeconds } else { [double]::MaxValue }
    # an old file is left from a closed client: sending it would show the character online
    if ($status -and $age -lt 90 -and ($status.LastWriteTime -ne $lastSent -or $wake)) {
      $wake = $false
      $r = Call 'Post' '/status' $status.FullName 'application/json' 10
      if ($r.code -eq 200) {
        $lastSent = $status.LastWriteTime; $refused = 0
        Put "$In\reply.json" $r.body
        if ("$(Get-Content "$In\pair.json" -Raw -ErrorAction SilentlyContinue)" -notmatch '"paired":true') {
          Put "$In\pair.json" '{"paired":true}'
          Note 'paired'
        }
        $statusEvery = [int](Field $r.body 'statusEvery'); if (-not $statusEvery) { $statusEvery = 30 }
        $minimapOn = $r.body -notmatch '"minimap":false'
        if ((Field $r.body 'commands') -ne '0') {
          $c = Call 'Get' '/commands' $null $null 10
          if ($c.code -eq 200) { Put "$In\commands.json" $c.body }
        }
        Note 'sending'
      } elseif (Revoked $r) {
        Unpair 'removed on the website'
        continue
      } elseif ($r.code -eq 401) {
        On-Refused
        Start-Sleep -Seconds 5
        continue
      } elseif ($r.code -eq 422) {
        $lastSent = $status.LastWriteTime
        Note 'the website refused a status (HTTP 422)'
      } else {
        Note "status failed: HTTP $($r.code)"
        Start-Sleep -Seconds 5
        continue
      }
    }

    $shot = Get-Item "$Out\capture.png" -ErrorAction SilentlyContinue
    if ($shot -and $shot.LastWriteTime -ne $lastCapture -and (Whole-Png $shot.FullName)) {
      if ((Call 'Post' '/capture' $shot.FullName 'image/png' 20).code -eq 200) { $lastCapture = $shot.LastWriteTime }
    }

    if (Test-Path "$Out\results.json") {
      foreach ($res in (Get-Content "$Out\results.json" -Raw | ConvertFrom-Json)) {
        Put "$Out\.result" (@{ ok = $res.ok; message = $res.message } | ConvertTo-Json -Compress)
        Call 'Post' "/commands/$($res.id)/result" "$Out\.result" 'application/json' 10 | Out-Null
      }
      Remove-Item -Force -ErrorAction SilentlyContinue "$Out\results.json", "$Out\.result"
    }

    # the client's own minimap sits in the write folder, two levels up. The clients there share it, so only the first
    # paired character sends it, and only after it changed.
    if ($minimapOn -and ($now - $minimapCheck).TotalSeconds -ge 60) {
      $minimapCheck = $now
      $first = Get-ChildItem $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { "$(Get-Content (Join-Path $_.FullName 'inbox\pair.json') -Raw -ErrorAction SilentlyContinue)" -match '"paired":true' } |
        Sort-Object Name | Select-Object -First 1
      if ($first -and $first.FullName -eq (Get-Item $Dir).FullName) {
        $map = Get-ChildItem (Split-Path $Parent) -Filter 'minimap*.otmm' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
          Select-Object -First 1
        $stamp = if ($map) { [string]$map.LastWriteTimeUtc.Ticks } else { '' }
        if ($map -and $stamp -ne "$(Get-Content $SentMap -Raw -ErrorAction SilentlyContinue)") {
          $code = (Call 'Post' '/minimap' $map.FullName 'application/octet-stream' 120).code
          if ($code -eq 200 -or $code -eq 409) { [IO.File]::WriteAllText($SentMap, $stamp) }
        }
      }
    }

    if ($statusEvery -le 2) {
      Start-Sleep -Seconds 1
    } elseif ($age -gt 300) {
      Start-Sleep -Seconds 10  # the client is closed or logged out: no request stays open
    } else {
      # someone opened the character, an alert fired or a command arrived: send the status again for a new pace
      $w = Call 'Get' '/wait?timeout=25' $null $null 30
      if ($w.code -eq 200) {
        if ($w.body -match '"wake":true') { $wake = $true }
      } elseif (Revoked $w) {
        Unpair 'removed on the website'
      } else {
        Start-Sleep -Seconds 5
      }
    }
  } catch {
    Note $_.Exception.Message
    Start-Sleep -Seconds 5
  }
}
