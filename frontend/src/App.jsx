import { useEffect, useRef, useState, useCallback } from 'react'
import { Map as MlMap, Marker, Popup, NavigationControl, LngLatBounds } from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import './App.css'

const BASEMAP = 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json'
const SYDNEY = { center: [151.0, -33.87], zoom: 11 }

function fmtDur(s) {
  if (s == null) return '—'
  const m = Math.round(s / 60)
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m} min`
}
function fmtDist(m) {
  if (m == null) return '—'
  return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`
}

function GeocodeInput({ label, placeholder, value, onSelect }) {
  const [q, setQ] = useState('')
  const [results, setResults] = useState([])
  const [open, setOpen] = useState(false)
  const timer = useRef(null)

  const search = (text) => {
    setQ(text)
    if (timer.current) clearTimeout(timer.current)
    if (text.length < 3) { setResults([]); return }
    timer.current = setTimeout(async () => {
      try {
        const r = await fetch(`/api/geocode?q=${encodeURIComponent(text)}`)
        const d = await r.json()
        setResults(d.features || [])
        setOpen(true)
      } catch { setResults([]) }
    }, 300)
  }

  return (
    <div className="geocode">
      <label>{label}</label>
      <input
        value={value ? value.label : q}
        placeholder={placeholder}
        onChange={(e) => { onSelect(null); search(e.target.value) }}
        onFocus={() => results.length && setOpen(true)}
      />
      {open && results.length > 0 && (
        <ul className="geocode-results">
          {results.map((f, i) => {
            const p = f.properties
            const label = [p.name, p.street, p.district || p.city, p.postcode].filter(Boolean).join(', ')
            return (
              <li key={i} onClick={() => { onSelect({ label, coords: f.geometry.coordinates }); setOpen(false) }}>
                {label}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

export default function App() {
  const mapRef = useRef(null)
  const mapObj = useRef(null)
  const markers = useRef([])
  const [origin, setOrigin] = useState(null)
  const [dest, setDest] = useState(null)
  const [profile, setProfile] = useState('foot-walking')
  const [safety, setSafety] = useState(0.6)
  const [afterDark, setAfterDark] = useState(false)
  const [showZones, setShowZones] = useState(true)
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    const map = new MlMap({ container: mapRef.current, style: BASEMAP, ...SYDNEY })
    mapObj.current = map
    window.__map = map // dev console handle
    map.addControl(new NavigationControl(), 'top-right')
    // container is sized by flexbox after fonts/CSS settle; re-measure once ready
    requestAnimationFrame(() => map.resize())

    map.on('load', async () => {
      // crash hotspots: heatmap zoomed out, circles zoomed in
      map.addSource('crashes', { type: 'geojson', data: '/api/hotspots' })
      map.addLayer({
        id: 'crash-heat', type: 'heatmap', source: 'crashes', maxzoom: 15,
        paint: {
          'heatmap-weight': ['interpolate', ['linear'], ['get', 'risk'], 1, 0.1, 10, 0.6, 26, 1],
          'heatmap-intensity': 0.6,
          'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 10, 8, 15, 22],
          'heatmap-color': ['interpolate', ['linear'], ['heatmap-density'],
            0, 'rgba(255,180,60,0)', 0.3, 'rgba(255,160,60,0.25)',
            0.6, 'rgba(255,100,40,0.5)', 1, 'rgba(220,30,30,0.75)'],
        },
      })
      map.addLayer({
        id: 'crash-pts', type: 'circle', source: 'crashes', minzoom: 13,
        paint: {
          'circle-radius': ['case', ['==', ['get', 'degree_of_crash'], 'Fatal'], 7, 4],
          'circle-color': ['case',
            ['==', ['get', 'degree_of_crash'], 'Fatal'], '#b3121f',
            ['==', ['get', 'degree_of_crash_detailed'], 'Serious Injury'], '#e85d04', '#f4a63b'],
          'circle-opacity': 0.8, 'circle-stroke-width': 1, 'circle-stroke-color': '#fff',
        },
      })
      map.on('click', 'crash-pts', (e) => {
        const p = e.features[0].properties
        new Popup({ closeButton: false })
          .setLngLat(e.lngLat)
          .setHTML(`<b>${p.degree_of_crash_detailed}</b> · ${p.year_of_crash}<br/>
            ${p.has_pedestrian === 'true' || p.has_pedestrian === true ? '🚶 Pedestrian ' : ''}
            ${p.has_bicycle === 'true' || p.has_bicycle === true ? '🚲 Cyclist' : ''}<br/>
            ${p.street_of_crash || ''}, ${p.town || ''}<br/>
            ${p['two-hour_intervals'] || ''} · ${p.natural_lighting || ''}`)
          .addTo(map)
      })

      // school zones
      map.addSource('zones', { type: 'geojson', data: '/api/school_zones' })
      map.addLayer({
        id: 'zones-fill', type: 'fill', source: 'zones',
        paint: { 'fill-color': '#7b2ff2', 'fill-opacity': 0.08 },
      })
      map.addLayer({
        id: 'zones-line', type: 'line', source: 'zones', minzoom: 12,
        paint: { 'line-color': '#7b2ff2', 'line-opacity': 0.4, 'line-width': 1.5 },
      })

      // schools
      map.addSource('schools', { type: 'geojson', data: '/api/schools' })
      map.addLayer({
        id: 'school-pts', type: 'circle', source: 'schools', minzoom: 12,
        paint: { 'circle-radius': 4, 'circle-color': '#2d6cdf', 'circle-opacity': 0.85, 'circle-stroke-width': 1, 'circle-stroke-color': '#fff' },
      })
      map.on('click', 'school-pts', (e) => {
        const p = e.features[0].properties
        new Popup({ closeButton: false })
          .setLngLat(e.lngLat)
          .setHTML(`<b>${p.name}</b><br/>${p.level || ''}<br/>${Math.round(p.enrolment) || '?'} students`)
          .addTo(map)
      })

      // route sources (empty until first query)
      for (const id of ['route-fast', 'route-safe', 'avoided']) {
        map.addSource(id, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } })
      }
      map.addLayer({
        id: 'avoided-fill', type: 'fill', source: 'avoided',
        paint: { 'fill-color': '#d90429', 'fill-opacity': 0.18 },
      })
      map.addLayer({
        id: 'route-fast-line', type: 'line', source: 'route-fast',
        layout: { 'line-cap': 'round' },
        paint: { 'line-color': '#8d99ae', 'line-width': 5, 'line-dasharray': [1.5, 1.5] },
      })
      map.addLayer({
        id: 'route-safe-line', type: 'line', source: 'route-safe',
        layout: { 'line-cap': 'round' },
        paint: { 'line-color': '#2b9348', 'line-width': 5 },
      })
    })
    return () => map.remove()
  }, [])

  useEffect(() => {
    const map = mapObj.current
    if (!map || !map.getLayer('zones-fill')) return
    const vis = showZones ? 'visible' : 'none'
    map.setLayoutProperty('zones-fill', 'visibility', vis)
    map.setLayoutProperty('zones-line', 'visibility', vis)
  }, [showZones])

  const doRoute = useCallback(async () => {
    if (!origin || !dest) return
    setLoading(true); setError(null)
    try {
      const r = await fetch('/api/route', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ start: origin.coords, end: dest.coords, profile, safety: Number(safety), after_dark: afterDark }),
      })
      if (!r.ok) throw new Error((await r.json()).detail || `HTTP ${r.status}`)
      const d = await r.json()
      setResult(d)
      const map = mapObj.current
      map.getSource('route-fast').setData(d.fastest.route)
      map.getSource('route-safe').setData(d.safest.route)
      map.getSource('avoided').setData(d.avoided_polygons)
      markers.current.forEach((m) => m.remove())
      markers.current = [
        new Marker({ color: '#2b9348' }).setLngLat(origin.coords).addTo(map),
        new Marker({ color: '#d90429' }).setLngLat(dest.coords).addTo(map),
      ]
      const coords = d.fastest.route.features[0].geometry.coordinates.concat(
        d.safest.route.features[0].geometry.coordinates)
      const b = coords.reduce((bb, c) => bb.extend(c), new LngLatBounds(coords[0], coords[0]))
      map.fitBounds(b, { padding: { top: 60, bottom: 60, left: 380, right: 60 } })
    } catch (e) {
      setError(String(e.message || e))
    } finally { setLoading(false) }
  }, [origin, dest, profile, safety, afterDark])

  const fast = result?.fastest?.stats
  const safe = result?.safest?.stats

  return (
    <div className="app">
      <div className="sidebar">
        <h1>SafeRoutes <span>Sydney</span></h1>
        <p className="tagline">Fastest vs safest walking &amp; cycling routes, powered by 5 years of real NSW crash data.</p>

        <GeocodeInput label="From" placeholder="Home address…" value={origin} onSelect={setOrigin} />
        <GeocodeInput label="To" placeholder="School or destination…" value={dest} onSelect={setDest} />

        <div className="row">
          <button className={profile === 'foot-walking' ? 'seg on' : 'seg'} onClick={() => setProfile('foot-walking')}>🚶 Walk</button>
          <button className={profile === 'cycling-regular' ? 'seg on' : 'seg'} onClick={() => setProfile('cycling-regular')}>🚲 Bike</button>
        </div>

        <label className="slider-label">Safety priority: {Math.round(safety * 100)}%</label>
        <input type="range" min="0" max="1" step="0.05" value={safety} onChange={(e) => setSafety(e.target.value)} />

        <label className="check">
          <input type="checkbox" checked={afterDark} onChange={(e) => setAfterDark(e.target.checked)} />
          🌙 After dark (weights night-time crashes higher)
        </label>
        <label className="check">
          <input type="checkbox" checked={showZones} onChange={(e) => setShowZones(e.target.checked)} />
          Show 40 km/h school zones
        </label>

        <button className="go" onClick={doRoute} disabled={!origin || !dest || loading}>
          {loading ? 'Routing…' : 'Find routes'}
        </button>
        {error && <div className="error">{error}</div>}

        {result && (
          <div className="compare">
            <div className="card fast">
              <h3>⚡ Fastest</h3>
              <div className="big">{fmtDur(fast.duration_s)}</div>
              <div>{fmtDist(fast.distance_m)}</div>
              <div className="risk">☠ {fast.crashes_within_30m} crashes on route<br />risk score {fast.risk_score}{fast.fatal_nearby > 0 && <b> · {fast.fatal_nearby} fatal</b>}</div>
            </div>
            <div className="card safe">
              <h3>🛡 Safest</h3>
              <div className="big">{fmtDur(safe.duration_s)}</div>
              <div>{fmtDist(safe.distance_m)}</div>
              <div className="risk">☠ {safe.crashes_within_30m} crashes on route<br />risk score {safe.risk_score}{safe.fatal_nearby > 0 && <b> · {safe.fatal_nearby} fatal</b>}</div>
            </div>
            {fast.risk_score > 0 && (
              <p className="verdict">
                {safe.risk_score < fast.risk_score
                  ? `Safest route cuts crash-risk exposure by ${Math.round((1 - safe.risk_score / fast.risk_score) * 100)}% for ${fmtDur(safe.duration_s - fast.duration_s)} extra.`
                  : 'The fastest route is already the safest for this trip.'}
              </p>
            )}
          </div>
        )}

        <footer>
          Crash data: Transport for NSW Road Crash Data 2020–2024 (CC BY 4.0).
          Not a substitute for adult supervision.
        </footer>
      </div>
      <div ref={mapRef} className="map" />
    </div>
  )
}
