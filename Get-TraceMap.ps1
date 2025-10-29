[CmdletBinding()]
param(
  [Parameter(Mandatory)][string[]]$Target,
  [int]$MaxHops = 30,
  [int]$TimeoutMs = 4000,
  [ValidateSet('ipinfo','ipapi')][string]$GeoProvider = $(if ($env:IPINFO_TOKEN) {'ipinfo'} else {'ipapi'}),
  [string]$ApiToken = $env:IPINFO_TOKEN,
  [string]$Json = ".\trace.json",
  [string]$Html = ".\trace.html",
  [switch]$Open
)

function Invoke-Trace {
  param([string]$TargetHost,[int]$MaxHops,[int]$TimeoutMs)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "tracert.exe"
  $psi.Arguments = "-d -h $MaxHops -w $([math]::Ceiling($TimeoutMs/1.0)) $TargetHost"
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  $lines = $out -split "`r?`n"
  $rxIp = [regex]'\b\d{1,3}(?:\.\d{1,3}){3}\b'
  $rxMs = [regex]'(\d+)\s*ms'
  $hops = @()
  foreach ($ln in $lines) {
    if ($ln -notmatch '^\s*\d+\s') { continue }
    $hopNum = [int]($ln -replace '^\s*(\d+).*','$1')
    $ipMatch = $rxIp.Matches($ln)
    $ip = if ($ipMatch.Count -gt 0) { $ipMatch[0].Value } else { $null }
    $rtts = @()
    foreach ($m in $rxMs.Matches($ln)) { $rtts += [int]$m.Groups[1].Value }
    $rtt = if ($rtts.Count) { [int]([math]::Round(($rtts | Measure-Object -Average).Average)) } else { $null }
    $hops += [pscustomobject]@{ Hop=$hopNum; IP=$ip; RTTms=$rtt }
  }
  $hops | Sort-Object Hop
}

function Get-Geo {
  param([string]$IP,[string]$Provider,[string]$Token)
  if (-not $IP) { return $null }
  try {
    switch ($Provider) {
      'ipinfo' {
        $u = "https://ipinfo.io/$IP/json"
        $hdr = @{}
        if ($Token) { $hdr.Authorization = "Bearer $Token" }
        $j = Invoke-RestMethod -Uri $u -Headers $hdr -TimeoutSec 6
        $lat=$null;$lon=$null
        if ($j.loc -and $j.loc -match ','){ $lat=[double]($j.loc.Split(',')[0]); $lon=[double]($j.loc.Split(',')[1]) }
        [pscustomobject]@{
          ip=$IP; lat=$lat; lon=$lon; city=$j.city; region=$j.region; country=$j.country
          org=$j.org; provider='ipinfo'
        }
      }
      default {
        $u = "http://ip-api.com/json/$IP?fields=status,country,regionName,city,lat,lon,org,query"
        $j = Invoke-RestMethod -Uri $u -TimeoutSec 6
        if ($j.status -ne 'success') { return $null }
        [pscustomobject]@{
          ip=$j.query; lat=[double]$j.lat; lon=[double]$j.lon; city=$j.city; region=$j.regionName; country=$j.country
          org=$j.org; provider='ip-api'
        }
      }
    }
  } catch { return $null }
}

function Build-Report {
  param(
    [string]$TargetHost,
    [object[]]$Hops,
    [string]$Provider,
    [string]$Token,
    [string]$JsonPath,
    [string]$HtmlPath,
    [switch]$Open
  )
  # Geo-enrich with a tiny cache for repeated IPs
  $geoCache = @{}
  $enriched = foreach ($h in $Hops) {
    $g = $null
    if ($h.IP) {
      if (-not $geoCache.ContainsKey($h.IP)) { $geoCache[$h.IP] = Get-Geo -IP $h.IP -Provider $Provider -Token $Token }
      $g = $geoCache[$h.IP]
    }
    [pscustomobject]@{
      Host=$TargetHost; Hop=$h.Hop; IP=$h.IP; RTTms=$h.RTTms
      City=$g.city; Region=$g.region; Country=$g.country; Org=$g.org; Lat=$g.lat; Lon=$g.lon
      CollectedAt=[datetime]::UtcNow
    }
  }

  # Write JSON (per target)
  $dir = Split-Path -Parent $JsonPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  ($enriched | ConvertTo-Json -Depth 5) | Out-File -Encoding utf8 $JsonPath

  # Build HTML
  $pts = $enriched | Where-Object { $_.Lat -and $_.Lon } | Sort-Object Hop
  $center = if ($pts) { @($pts[0].Lat, $pts[0].Lon) } else { @(20,0) }
  $rows = ($enriched | ForEach-Object {
    "<tr><td>$($_.Hop)</td><td>$($_.IP)</td><td>$($_.RTTms) ms</td><td>$($_.City), $($_.Region), $($_.Country)</td><td>$($_.Org)</td></tr>"
  }) -join ""
  $markers = ($pts | ForEach-Object {
    $label = [System.Web.HttpUtility]::JavaScriptStringEncode(("{0} • {1} • {2}ms" -f $_.IP, ($_.City ?? ''), ($_.RTTms ?? '')))
    "[{0}, {1}, ""{2}""]" -f [string]$_.Lat, [string]$_.Lon, $label
  }) -join ",`n"

  $html = @"
<!doctype html><meta charset="utf-8"><title>TraceMap: $TargetHost</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
body{font-family:ui-sans-serif,Segoe UI,Roboto,Arial;margin:0;display:grid;grid-template-columns:1fr 440px;grid-template-rows:auto 1fr;height:100vh}
header{grid-column:1/3;padding:12px 16px;border-bottom:1px solid #eee}
#map{height:100%} aside{border-left:1px solid #eee;overflow:auto}
table{width:100%;border-collapse:collapse} th,td{padding:8px;border-bottom:1px solid #f0f0f0}
.small{color:#666}
</style>
<header>
  <h2 style="margin:0">Trace to $TargetHost</h2>
  <div class="small">Geo by $Provider • Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</header>
<div id="map"></div>
<aside>
  <table>
    <thead><tr><th>Hop</th><th>IP</th><th>RTT</th><th>Location</th><th>Org</th></tr></thead>
    <tbody>$rows</tbody>
  </table>
</aside>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const map = L.map('map').setView([$($center[0]), $($center[1])], 4);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'© OpenStreetMap'}).addTo(map);
const hops = [
$markers
];
const latlngs = [];
hops.forEach(([lat,lon,label])=>{
  latlngs.push([lat,lon]);
  L.circleMarker([lat,lon],{radius:5}).addTo(map).bindPopup(label);
});
if(latlngs.length>1){ L.polyline(latlngs,{weight:3}).addTo(map); map.fitBounds(latlngs,{padding:[20,20]}); }
</script>
"@

  $dir2 = Split-Path -Parent $HtmlPath
  if ($dir2 -and -not (Test-Path $dir2)) { New-Item -ItemType Directory -Force -Path $dir2 | Out-Null }
  $html | Out-File -Encoding utf8 $HtmlPath
  Write-Host "[OK] Wrote JSON -> $JsonPath"
  Write-Host "[OK] Wrote HTML -> $HtmlPath"
  if ($Open) { Start-Process -FilePath $HtmlPath | Out-Null }
  $enriched
}

# ---- main loop per target ----
$all = @()
foreach($t in $Target){
  Write-Host "Tracing $t ..."
  $hops = Invoke-Trace -TargetHost $t -MaxHops $MaxHops -TimeoutMs $TimeoutMs

  # per-target output files (avoid overwrites)
  $safe = ($t -replace '[:\\\/\?\*\|"<>\s]','_')
  $outDir = ".\reports"
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
  $jsonPath = if ($PSBoundParameters.ContainsKey('Json')) { $Json } else { Join-Path $outDir "TraceMap-$safe.json" }
  $htmlPath = if ($PSBoundParameters.ContainsKey('Html')) { $Html } else { Join-Path $outDir "TraceMap-$safe.html" }

  $all += Build-Report -TargetHost $t -Hops $hops -Provider $GeoProvider -Token $ApiToken -JsonPath $jsonPath -HtmlPath $htmlPath -Open:$Open
}

# exit code (any geolocated hops? if none, warn but succeed with 2)
if (-not ($all | Where-Object { $_.Lat -and $_.Lon })) { exit 2 } else { exit 0 }

