# TraceRoute + GeoIP Mapper (PowerShell)

Trace to a target, GeoIP each hop, and render an interactive Leaflet map.

---

# Requirements  

- Windows PowerShell 5.1 or PowerShell 7+  
- Internet access (for GeoIP + map tiles)  

---

# Usage  

Basic (uses ip-api.com fallback):

.\Get-TraceMap.ps1 -Target cloudflare.com -Open

Use ipinfo (recommended; set token once):

$env:IPINFO_TOKEN = 'YOUR_TOKEN'  
.\Get-TraceMap.ps1 -Target cloudflare.com -GeoProvider ipinfo -Open  

Multiple targets, custom outputs:

.\Get-TraceMap.ps1 -Target cloudflare.com,github.com -Json .\out\trace.json -Html .\out\trace.html -Open

---

# Output

JSON: array of hops with IP, RTT, city/region/country, org, lat/lon.

HTML: Leaflet map with markers + polyline and a side table.

---

# Notes

- If no token is provided, script uses ip-api.com free tier (coarse accuracy, rate limits).

- First geolocated hop is used as the initial map center; map auto-fits when multiple hops resolve.

- Some hops (private IPs, timeouts) won’t have GeoIP data—those still appear in the table.
