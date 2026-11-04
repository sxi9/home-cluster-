<#
.SYNOPSIS
  worker.ps1 - join this Windows PC to the home cluster without rebooting into Ubuntu.

.DESCRIPTION
  Native Windows worker for the MODEL POOL only (no k3s): it runs llama.cpp's
  rpc-server as a startup task so the PC's RAM and GPU (CUDA or Vulkan) join
  `cluster run`, plus a small agent that heartbeats to the head so the PC shows
  on the dashboard. Uses the official prebuilt llama.cpp release matching the
  tag the head pinned, so nothing is compiled here.

  Run in an elevated PowerShell (what head.sh prints):
    powershell -ExecutionPolicy Bypass -c "iwr -useb http://HEAD:8787/worker.ps1 -OutFile $env:TEMP\worker.ps1; & $env:TEMP\worker.ps1"
  Options:
    -Gpu auto|cuda|vulkan|cpu   -Name NAME   -Head IP   -Join URL   -ReserveMB 4096
    -DryRun   -Leave

  State it leaves: C:\home-cluster\ (binaries, worker.env, agent.ps1), two
  scheduled tasks (home-cluster rpc-server, home-cluster agent), two firewall
  rules, and sleep disabled while plugged in.
#>
[CmdletBinding()]
param(
  [string]$Join = "",
  [string]$Head = "",
  [string]$Name = "",
  [ValidateSet("auto","cuda","vulkan","cpu")][string]$Gpu = "auto",
  [int]$RpcPort = 50052,
  [int]$ReserveMB = 4096,
  [int]$AgentPort = 8788,
  [string]$LlamaTag = "",
  [switch]$DryRun,
  [switch]$Leave
)
$ErrorActionPreference = "Stop"
$JoinUrlDefault = ""     # filled in by the head when it serves this file
if (-not $Join) { $Join = $JoinUrlDefault }
$Root = "C:\home-cluster"
$Bin  = "$Root\llama"
$EnvFile = "$Root\worker.env"
$TaskRpc = "home-cluster rpc-server"
$TaskAgent = "home-cluster agent"

function Log($m)  { Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }
function Run($desc, [scriptblock]$b) { if ($DryRun) { Write-Host "    + $desc" } else { & $b } }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { Die "run this from an elevated (Administrator) PowerShell" }

if ($Leave) {
  Log "leaving the cluster"
  foreach ($t in $TaskRpc, $TaskAgent) { Run "unregister task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } }
  Run "stop rpc-server" { Get-Process rpc-server -ErrorAction SilentlyContinue | Stop-Process -Force }
  Run "remove firewall rules" { Get-NetFirewallRule -DisplayName "home-cluster*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
  Run "remove $Root" { Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
  Log "left"; exit 0
}

# ---------------------------------------------------------------- preflight
Log "preflight"
if ((Test-Path $EnvFile) -and -not $Join -and -not $Head) {
  Get-Content $EnvFile | Where-Object { $_ -match '^(JOIN_URL|HEAD)=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; if ($k -eq 'JOIN_URL') { $Join = $v } elseif ($k -eq 'HEAD' -and -not $Head) { $Head = $v }
  }
}
if (-not $Join -and $Head) { $Join = "http://${Head}:8787" }
if (-not $Join) { Die "no head: pass -Head IP or -Join http://IP:8787 (or use the command head.sh printed)" }
$pins = @{}
try {
  (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$Join/cluster.env").Content -split "`n" | Where-Object { $_ -match '^[A-Z0-9_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; $pins[$k] = $v.Trim()
  }
  Log "found head's join service at $Join"
} catch { Warn "join service at $Join not reachable; continuing with flags only" }
if (-not $Head) { $Head = if ($pins.HEAD) { $pins.HEAD } else { ([uri]$Join).Host } }
if (-not $LlamaTag) { $LlamaTag = $pins.LLAMA_TAG }
if ($pins.RPC_PORT -and $RpcPort -eq 50052) { $RpcPort = [int]$pins.RPC_PORT }

# LAN address: the interface with the default route; Ethernet beats Wi-Fi
$cfgs = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
$cfg = $cfgs | Sort-Object { if ($_.NetAdapter.PhysicalMediaType -match '802\.11|Wireless') { 1 } else { 0 } } | Select-Object -First 1
if (-not $cfg) { Die "no network interface with a default route" }
$LanIp = $cfg.IPv4Address.IPAddress
$LinkType = if ($cfg.NetAdapter.PhysicalMediaType -match '802\.11|Wireless') { "wifi" } else { "wired" }
if ($LinkType -eq "wifi") { Warn "Wi-Fi link: works, but caps the cluster's tokens/sec" }
if (-not $Name) { $Name = $env:COMPUTERNAME.ToLower() }

# GPU
$video = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } | Select-Object -First 1
$GpuName = if ($video) { $video.Name } else { "" }
$hasNvidiaSmi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
if ($Gpu -eq "auto") {
  if ($GpuName -match 'NVIDIA' -and $hasNvidiaSmi) { $Gpu = "cuda" }
  elseif ($GpuName -match 'NVIDIA|AMD|Radeon|Intel|Arc') { $Gpu = "vulkan" }
  else { $Gpu = "cpu" }
}
$MemTotalMB = [int]((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1024)
$RpcMemMB = $MemTotalMB - $ReserveMB
if ($RpcMemMB -lt 512) { Die "only $MemTotalMB MB RAM; lower -ReserveMB" }
$Threads = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Write-Host @"
    node        : $Name ($MemTotalMB MB RAM, $Threads threads)
    head        : $Head via $Join
    lan         : $($cfg.InterfaceAlias) $LanIp ($LinkType)
    gpu         : $Gpu $(if ($GpuName) { "($GpuName)" })
    rpc-server  : ${LanIp}:$RpcPort, $(if ($Gpu -eq 'cpu') { "$RpcMemMB MB RAM offered" } else { "GPU memory offered" })
    llama.cpp   : $(if ($LlamaTag) { $LlamaTag } else { "latest release (head did not pin a tag; builds may mismatch)" })
"@

# ---------------------------------------------------------------- llama.cpp release
Log "llama.cpp prebuilt release ($Gpu)"
$api = if ($LlamaTag) { "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" } else { "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" }
$rel = Invoke-RestMethod -UseBasicParsing -Headers @{ "User-Agent" = "home-cluster" } $api
$assets = $rel.assets | ForEach-Object { $_.name }
$want = switch ($Gpu) {
  "cuda"   { @('win.*cuda.*12.*x64\.zip', 'cudart.*cuda.*12.*x64\.zip') }
  "vulkan" { @('win.*vulkan.*x64\.zip') }
  default  { @('win.*(cpu|avx2).*x64\.zip') }
}
$picked = foreach ($pat in $want) { $assets | Where-Object { $_ -match $pat -and $_ -notmatch 'arm64' } | Select-Object -First 1 }
if (-not $picked -or $picked.Count -lt $want.Count) { Die "no matching Windows asset in release $($rel.tag_name) for $Gpu (have: $($assets -join ', '))" }
$marker = "$Bin\RELEASE"
if ((Test-Path "$Bin\rpc-server.exe") -and (Test-Path $marker) -and ((Get-Content $marker) -eq "$($rel.tag_name):$Gpu")) {
  Log "already have $($rel.tag_name) for $Gpu"
} else {
  Run "download + extract $($picked -join ', ') to $Bin" {
    New-Item -ItemType Directory -Force $Bin | Out-Null
    Get-ChildItem $Bin -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    foreach ($a in $picked) {
      $url = ($rel.assets | Where-Object { $_.name -eq $a }).browser_download_url
      $zip = "$env:TEMP\$a"
      Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
      Expand-Archive -Force $zip "$Bin\_x"
      Get-ChildItem "$Bin\_x" -Recurse -File | Move-Item -Destination $Bin -Force
      Remove-Item -Recurse -Force "$Bin\_x"; Remove-Item -Force $zip
    }
    if ((Test-Path "$Bin\ggml-rpc-server.exe") -and -not (Test-Path "$Bin\rpc-server.exe")) { Copy-Item "$Bin\ggml-rpc-server.exe" "$Bin\rpc-server.exe" }
    if (-not (Test-Path "$Bin\rpc-server.exe")) { throw "the release zip has no rpc-server.exe / ggml-rpc-server.exe; build llama.cpp with -DGGML_RPC=ON yourself and put rpc-server.exe in $Bin" }
    Set-Content $marker "$($rel.tag_name):$Gpu"
  }
}

# ---------------------------------------------------------------- config
Log "config: $EnvFile"
$envText = @"
# home-cluster windows worker settings - written by worker.ps1
ROLE=worker
OS=windows
NODE_NAME=$Name
HEAD=$Head
JOIN_URL=$Join
LAN_IP=$LanIp
LINK_TYPE=$LinkType
RPC_PORT=$RpcPort
RPC_MEM_MB=$RpcMemMB
RPC_THREADS=$Threads
GPU=$Gpu
GPU_NAME=$GpuName
AGENT_PORT=0
LLAMA_REF=$($rel.tag_name)
"@
Run "write $EnvFile" { New-Item -ItemType Directory -Force $Root | Out-Null; Set-Content -Path $EnvFile -Value $envText }

# agent: heartbeat only (the planner uses the heartbeat when there is no /metrics endpoint)
$agent = @'
$ErrorActionPreference = "Continue"
$env = @{}; Get-Content "C:\home-cluster\worker.env" | Where-Object { $_ -match '^[A-Z0-9_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $env[$k] = $v }
function RpcUp($h, $p) { try { $c = New-Object Net.Sockets.TcpClient; $r = $c.BeginConnect($h, [int]$p, $null, $null); $ok = $r.AsyncWaitHandle.WaitOne(500) -and $c.Connected; $c.Close(); $ok } catch { $false } }
while ($true) {
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $gpu = @{ kind = $env.GPU; name = $env.GPU_NAME; vram_total_mb = $null; vram_free_mb = $null; util_pct = $null; temp_c = $null }
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
      $q = (& nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null) -split ','
      if ($q.Count -ge 5) { $gpu.name = $q[0].Trim(); $gpu.vram_total_mb = [int]$q[1]; $gpu.vram_free_mb = [int]$q[1] - [int]$q[2]; $gpu.util_pct = [int]$q[3]; $gpu.temp_c = [int]$q[4] }
    }
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $battery = if ($bat) { @{ percent = [int]$bat.EstimatedChargeRemaining; charging = ($bat.BatteryStatus -in 2,3,6,7,8,9); status = "$($bat.BatteryStatus)" } } else { $null }
    $body = @{
      name = $env.NODE_NAME; role = "worker"; os = "windows"; model = (Get-CimInstance Win32_ComputerSystem).Model; arch = $env:PROCESSOR_ARCHITECTURE.ToLower()
      link = $env.LINK_TYPE; lan_ip = $env.LAN_IP; agent_port = 0; cpus = [int]$env.RPC_THREADS; load1 = $null
      mem = @{ total_mb = [int]($os.TotalVisibleMemorySize/1024); free_mb = [int]($os.FreePhysicalMemory/1024); swap_total_mb = 0; swap_free_mb = 0 }
      gpu = $gpu; temp_c = $null; battery = $battery
      rpc = @{ port = [int]$env.RPC_PORT; listening = (RpcUp $env.LAN_IP $env.RPC_PORT); mem_mb = [int]$env.RPC_MEM_MB }
      llama_ref = $env.LLAMA_REF; uptime_s = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds; ts = [double](Get-Date -UFormat %s)
    } | ConvertTo-Json -Depth 4 -Compress
    Invoke-RestMethod -UseBasicParsing -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5 "$($env.JOIN_URL)/api/heartbeat" | Out-Null
  } catch { }
  Start-Sleep -Seconds 10
}
'@
Run "write $Root\agent.ps1" { Set-Content -Path "$Root\agent.ps1" -Value $agent }

# ---------------------------------------------------------------- tasks, firewall, power
Log "scheduled tasks (run at startup as SYSTEM)"
$rpcArgs = "--host $LanIp --port $RpcPort --threads $Threads"   # RPC_MEM_MB is a planner-side cap
Run "register '$TaskRpc': rpc-server.exe $rpcArgs" {
  $a = New-ScheduledTaskAction -Execute "$Bin\rpc-server.exe" -Argument $rpcArgs -WorkingDirectory $Bin
  $t = New-ScheduledTaskTrigger -AtStartup
  $s = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -Force -TaskName $TaskRpc -Action $a -Trigger $t -Settings $s -User "SYSTEM" -RunLevel Highest | Out-Null
  Start-ScheduledTask -TaskName $TaskRpc
}
Run "register '$TaskAgent'" {
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $Root\agent.ps1"
  $t = New-ScheduledTaskTrigger -AtStartup
  $s = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -Force -TaskName $TaskAgent -Action $a -Trigger $t -Settings $s -User "SYSTEM" -RunLevel Highest | Out-Null
  Start-ScheduledTask -TaskName $TaskAgent
}
Log "firewall: allow rpc-server from the LAN"
Run "firewall rule for $RpcPort/tcp" {
  Get-NetFirewallRule -DisplayName "home-cluster*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName "home-cluster rpc-server" -Direction Inbound -Protocol TCP -LocalPort $RpcPort -Action Allow -Profile Private,Domain | Out-Null
}
Log "power: no sleep while plugged in, lid close does nothing"
Run "powercfg" {
  powercfg /change standby-timeout-ac 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  powercfg /setactive SCHEME_CURRENT | Out-Null
}

Log "done"
Write-Host @"

  $Name is a Windows worker for head $Head ($Gpu backend, llama.cpp $($rel.tag_name)).
  check it:   Get-ScheduledTask 'home-cluster*' | Select TaskName, State
              Get-Process rpc-server
  on the head: cluster nodes   (this PC should be awake, rpc up)
  Note: Windows joins the model pool only, not k3s. Re-run worker.ps1 any time.
"@
