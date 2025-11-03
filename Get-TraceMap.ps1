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

function Ensure-LeafletAssets {
  param([string]$AssetRoot)  # e.g. ...\reports\assets\leaflet

  $cssPath = Join-Path $AssetRoot 'leaflet.css'
  $jsPath  = Join-Path $AssetRoot 'leaflet.js'

  if ( (Test-Path $cssPath) -and (Test-Path $jsPath) ) { return @($cssPath,$jsPath) }

  if (-not (Test-Path $AssetRoot)) {
    New-Item -ItemType Directory -Force -Path $AssetRoot | Out-Null
  }

  $sources = @(
    @{ css='https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
       js ='https://unpkg.com/leaflet@1.9.4/dist/leaflet.js' },
    @{ css='https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css';
       js ='https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js' },
    @{ css='https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.css';
       js ='https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js' }
  )

  foreach ($s in $sources) {
    try {
      if (-not (Test-Path $cssPath)) {
        Invoke-WebRequest -Uri $s.css -OutFile $cssPath -UseBasicParsing -TimeoutSec 15
      }
      if (-not (Test-Path $jsPath)) {
        Invoke-WebRequest -Uri $s.js  -OutFile $jsPath  -UseBasicParsing -TimeoutSec 15
      }
    } catch {
      Remove-Item -ErrorAction SilentlyContinue $cssPath,$jsPath
    }
    if ( (Test-Path $cssPath) -and (Test-Path $jsPath) ) { break }
  }

  if (-not ( (Test-Path $cssPath) -and (Test-Path $jsPath) )) {
    throw "Could not download Leaflet assets from any mirror."
  }
  @($cssPath,$jsPath)
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

# ensure local leaflet assets next to the HTML file
$assetDir = Join-Path (Split-Path -Parent $HtmlPath) 'assets\leaflet'
$paths = Ensure-LeafletAssets -AssetRoot $assetDir
$leafletCss = Get-Content -LiteralPath $paths[0] -Raw
$leafletJs  = Get-Content -LiteralPath $paths[1] -Raw

$html = @"
<!doctype html><meta charset="utf-8"><title>TraceMap: $TargetHost</title>
<style>
$($leafletCss)
</style>
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
  #map{ height:calc(100vh - 56px); min-height:400px; background:#f8fafc; outline:1px solid #e5e7eb; }
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
<script>
$($leafletJs)
</script>
<script>
  // --- initialize map container
  const map = L.map('map', { zoomControl: true });

  // helper: pick a sane center if no points
  const defaultCenter = [$($center[0]), $($center[1])];

  // --- robust basemap loader with fallbacks and diagnostics
  function addLayer(url, attribution) {
    return L.tileLayer(url, { maxZoom: 19, attribution });
  }

  const candidates = [
    { url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      att: '© OpenStreetMap' },
    { url: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
      att: '© OpenStreetMap' },
    { url: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
      att: '© OpenStreetMap, © CARTO' }
  ];

  async function pickBasemap() {
    // try to load a single known tile first; if it errors, try the next
    for (const c of candidates) {
      try {
        await new Promise((resolve, reject) => {
          const test = new Image();
          test.crossOrigin = 'anonymous';
          test.onload = () => resolve();
          test.onerror = () => reject();
          // z/x/y = 1/1/1 is tiny and quick
          const testUrl = c.url
            .replace('{s}', 'a')
            .replace('{z}', '1').replace('{x}', '1').replace('{y}', '1');
          test.src = testUrl;
        });
        addLayer(c.url, c.att).addTo(map);
        return c.url;
      } catch { /* try next */ }
    }
    // last resort: draw a neutral background so the pane isn't blank
    const pane = map.createPane('empty');
    const el = L.DomUtil.create('div', '', pane);
    el.style.cssText = 'background:#f3f4f6;width:100%;height:100%;';
    // give users a visible hint
    const note = L.control({position:'topright'});
    note.onAdd = () => {
      const d = L.DomUtil.create('div');
      d.style.cssText = 'background:#fff;border:1px solid #ddd;padding:8px 10px;border-radius:6px;font:12px ui-sans-serif';
      d.textContent = 'Basemap tiles blocked or unavailable.';
      return d;
    };
    note.addTo(map);
    return 'none';
  }

  // --- marker color by RTT
  function colorFor(rtt){
    if (rtt == null || rtt < 0) return '#9ca3af';   // unknown
    if (rtt <= 20) return '#22c55e';                // good
    if (rtt <= 50) return '#f59e0b';                // warning
    return '#ef4444';                                // high
  }

  // --- your hop data (already rendered server-side)
  const hops = [
  $markers
  ];

  (async function main(){
    const chosen = await pickBasemap();

    // lay out map now that CSS/DOM is ready
    function kick(){ try{ map.invalidateSize(); }catch(e){} }
    window.addEventListener('load', kick);
    if (window.ResizeObserver) new ResizeObserver(kick).observe(document.body);
    else setTimeout(kick, 120);

    // add points (if any)
    const latlngs = [];
    for (const h of hops){
      if (typeof h.lat === 'number' && typeof h.lon === 'number'){
        latlngs.push([h.lat, h.lon]);
        const c = colorFor(h.rtt);
        L.circleMarker([h.lat, h.lon], {
          radius: 6, color: c, fillColor: c, fillOpacity: 0.9, weight: 1
        }).addTo(map).bindPopup(h.label);
      }
    }

    // view
    if (latlngs.length > 1){
      map.fitBounds(latlngs, {padding:[20,20]});
    } else if (latlngs.length === 1){
      map.setView(latlngs[0], 9);
    } else {
      map.setView(defaultCenter, 3);   // still show a world view even with no markers
    }

    // legend (only if basemap rendered)
    if (chosen !== 'none') {
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
    }
  })();
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

