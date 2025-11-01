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
    $rtt   = if ($_.RTTms) { [int]$_.RTTms } else { -1 }  # -1 = unknown
    "{ lat: $([string]$_.Lat), lon: $([string]$_.Lon), hop: $($_.Hop), rtt: $rtt, label: ""$label"" }"
  }) -join ",`n"

$html = @"
<!doctype html><meta charset="utf-8"><title>TraceMap: $TargetHost</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css">
<style>
  :root{--muted:#6b7280}
  body{
    font-family:ui-sans-serif,Segoe UI,Roboto,Arial;
    margin:0;
    height:100vh;
    display:grid;
    grid-template-columns:1fr 440px;
    grid-template-rows:auto 1fr;
  }
  header{grid-column:1/3;padding:12px 16px;border-bottom:1px solid #eee}
  /* Make the map always have height */
  #map{
    height:calc(100vh - 56px);   /* header ~56px */
    min-height:400px;            /* safety fallback */
  }
  aside{border-left:1px solid #eee;overflow:auto}
  table{width:100%;border-collapse:collapse}
  th,td{padding:8px;border-bottom:1px solid #f0f0f0}
  .small{color:var(--muted)}
</style>
<header>
  <h2 style="margin:0">Trace to $TargetHost</h2>
  <div class="small">Geo by $GeoProvider • Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</header>
<div id="map"></div>
<aside>
  <table>
    <thead><tr><th>Hop</th><th>IP</th><th>RTT</th><th>Location</th><th>Org</th></tr></thead>
    <tbody>$rows</tbody>
  </table>
</aside>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script src="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
  const map = L.map('map').setView([$($center[0]), $($center[1])], 4);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, attribution: '© OpenStreetMap'
  }).addTo(map);

  // Make sure the map actually paints even if layout finishes late
  function kick(){ try{ map.invalidateSize(); }catch(e){} }
  window.addEventListener('load', kick);
  // If the browser supports it, keep the map in sync with any resizes
  if (window.ResizeObserver) {
    new ResizeObserver(kick).observe(document.body);
  } else {
    setTimeout(kick, 100); // simple fallback
  }

  function colorFor(rtt){
    if (rtt < 0) return '#9ca3af';   // unknown
    if (rtt <= 20) return '#22c55e'; // good
    if (rtt <= 50) return '#f59e0b'; // warning
    return '#ef4444';                // high
  }

  const hops = [
$markers
  ];

  const latlngs = [];
  hops.forEach(h => {
    if (typeof h.lat === 'number' && typeof h.lon === 'number'){
      latlngs.push([h.lat, h.lon]);
      const c = colorFor(h.rtt ?? -1);
      L.circleMarker([h.lat, h.lon], {
        radius: 6, color: c, fillColor: c, fillOpacity: 0.9, weight: 1
      }).addTo(map).bindPopup(h.label);
    }
  });

  if (latlngs.length > 1) {
    L.polyline(latlngs, {weight: 3}).addTo(map);
    map.fitBounds(latlngs, {padding:[20,20]});
  }

  // legend
  const legend = L.control({position:'bottomright'});
  legend.onAdd = function(){
    const div = L.DomUtil.create('div','legend');
    div.innerHTML = `
      <div style="background:#fff;padding:8px 10px;border:1px solid #ddd;border-radius:6px;font:12px/1.3 ui-sans-serif,Segoe UI,Roboto,Arial;">
        <div style="font-weight:600;margin-bottom:6px">RTT legend</div>
        <div><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:50%;margin-right:6px;"></span> ≤ 20 ms</div>
        <div><span style="display:inline-block;width:10px;height:10px;background:#f59e0b;border-radius:50%;margin-right:6px;"></span> 21–50 ms</div>
        <div><span style="display:inline-block;width:10px;height:10px;background:#ef4444;border-radius:50%;margin-right:6px;"></span> > 50 ms</div>
        <div><span style="display:inline-block;width:10px;height:10px;background:#9ca3af;border-radius:50%;margin-right:6px;"></span> unknown</div>
      </div>`;
    return div;
  };
  legend.addTo(map);
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

