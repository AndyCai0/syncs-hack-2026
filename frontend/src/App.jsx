import { useEffect, useRef, useState, useCallback } from 'react'
import { Map as MlMap, Marker, Popup, NavigationControl, LngLatBounds } from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import './App.css'

const BASEMAP = {
  version: 8,
  sources: {
    osm: {
      type: 'raster',
      tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
      tileSize: 256,
      attribution: '© OpenStreetMap contributors',
    },
  },
  layers: [{ id: 'osm', type: 'raster', source: 'osm' }],
}
const SYDNEY = { center: [151.0, -33.87], zoom: 11 }
const PREFERENCES = [
  { label: 'Low', value: 0.25 },
  { label: 'Balanced', value: 0.6 },
  { label: 'High', value: 1.0 },
]

function fmtDur(s) {
  if (s == null) return '—'
  const m = Math.round(s / 60)
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m} min`
}
function fmtDist(m) {
  if (m == null) return '—'
  return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`
}

function GeocodeInput({ label, placeholder, value, onSelect, onError }) {
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
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        const d = await r.json()
        setResults(d.features || [])
        setOpen(true)
        onError(null)
      } catch {
        setResults([])
        setOpen(false)
        onError('Place search is unavailable. Use a verified demo route below.')
      }
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
  const [safety, setSafety] = useState(0.6)
  const [afterDark, setAfterDark] = useState(false)
  const [showZones, setShowZones] = useState(true)
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  const [geocodeError, setGeocodeError] = useState(null)
  const [mapNotice, setMapNotice] = useState(null)
  const [demoCases, setDemoCases] = useState([])

  useEffect(() => {
    fetch('/api/demo_cases')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
      })
      .then(setDemoCases)
      .catch(() => setError('Verified demo routes could not be loaded. Check that the backend is running.'))
  }, [])

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
      for (const id of ['route-fast', 'route-lower', 'avoided']) {
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
        id: 'route-lower-line', type: 'line', source: 'route-lower',
        layout: { 'line-cap': 'round' },
        paint: { 'line-color': '#2b9348', 'line-width': 5 },
      })
    })
    map.on('error', () => {
      setMapNotice('The online basemap may be unavailable; verified coordinates and local routing still work.')
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

  const doRoute = useCallback(async (
    routeOrigin = origin,
    routeDest = dest,
    routeSafety = safety,
    routeAfterDark = afterDark,
  ) => {
    if (!routeOrigin || !routeDest) return
    setLoading(true); setError(null)
    try {
      const r = await fetch('/api/route', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          start: routeOrigin.coords,
          end: routeDest.coords,
          profile: 'foot-walking',
          safety: Number(routeSafety),
          after_dark: routeAfterDark,
          engine: 'local',
        }),
      })
      if (!r.ok) throw new Error((await r.json()).detail || `HTTP ${r.status}`)
      const d = await r.json()
      setResult(d)
      const map = mapObj.current
      map?.getSource('route-fast')?.setData(d.fastest.route)
      map?.getSource('route-lower')?.setData(d.lower_hazard.route)
      map?.getSource('avoided')?.setData(d.avoided_polygons)
      markers.current.forEach((m) => m.remove())
      if (map) {
        markers.current = [
          new Marker({ color: '#2b9348' }).setLngLat(routeOrigin.coords).addTo(map),
          new Marker({ color: '#d90429' }).setLngLat(routeDest.coords).addTo(map),
        ]
      }
      const coords = d.fastest.route.features[0].geometry.coordinates.concat(
        d.lower_hazard.route.features[0].geometry.coordinates)
      const b = coords.reduce((bb, c) => bb.extend(c), new LngLatBounds(coords[0], coords[0]))
      const narrowLayout = window.matchMedia('(max-width: 900px)').matches
      const padding = narrowLayout
        ? { top: 40, bottom: 40, left: 40, right: 40 }
        : { top: 60, bottom: 60, left: 420, right: 60 }
      map?.fitBounds(b, { padding })
    } catch (e) {
      setError(String(e.message || e))
    } finally { setLoading(false) }
  }, [origin, dest, safety, afterDark])

  const runDemo = useCallback((demo) => {
    const routeOrigin = { label: demo.origin_label, coords: demo.start }
    const routeDest = {
      label: `${demo.school_name} — approximate destination`,
      coords: demo.end,
    }
    setOrigin(routeOrigin)
    setDest(routeDest)
    setSafety(1.0)
    setAfterDark(Boolean(demo.after_dark))
    setGeocodeError(null)
    doRoute(routeOrigin, routeDest, 1.0, Boolean(demo.after_dark))
  }, [doRoute])

  const fast = result?.fastest?.stats
  const lower = result?.lower_hazard?.stats

  return (
    <div className="app">
      <div className="sidebar">
        <h1>SafeRoutes <span>Sydney</span></h1>
        <p className="tagline">Compare walking routes for Sydney school journeys using reported pedestrian crash history.</p>

        {demoCases.length > 0 && (
          <section className="demo-cases" aria-label="Verified demo routes">
            <div className="section-label">Try a verified demo route</div>
            <div className="demo-grid">
              {demoCases.map((demo) => (
                <button key={demo.id} onClick={() => runDemo(demo)} disabled={loading}>
                  <strong>{demo.school_name}</strong>
                  <span>{fmtDist(demo.fastest.distance_m)} walk · {Math.round((demo.detour_ratio - 1) * 100)}% detour</span>
                </button>
              ))}
            </div>
          </section>
        )}

        <GeocodeInput label="From" placeholder="Home address…" value={origin} onSelect={setOrigin} onError={setGeocodeError} />
        <GeocodeInput label="To" placeholder="School or destination…" value={dest} onSelect={setDest} onError={setGeocodeError} />
        {geocodeError && <div className="notice">{geocodeError}</div>}

        <div>
          <div className="section-label">Historical hazard avoidance</div>
          <div className="row preference" role="group" aria-label="Historical hazard avoidance">
            {PREFERENCES.map((option) => (
              <button
                key={option.label}
                className={Number(safety) === option.value ? 'seg on' : 'seg'}
                onClick={() => setSafety(option.value)}
              >
                {option.label}
              </button>
            ))}
          </div>
        </div>

        <label className="check">
          <input type="checkbox" checked={afterDark} onChange={(e) => setAfterDark(e.target.checked)} />
          🌙 After dark (weights night-time crashes higher)
        </label>
        <label className="check">
          <input type="checkbox" checked={showZones} onChange={(e) => setShowZones(e.target.checked)} />
          Show 40 km/h school zones
        </label>

        <button className="go" onClick={() => doRoute()} disabled={!origin || !dest || loading}>
          {loading ? 'Routing…' : 'Find routes'}
        </button>
        {error && <div className="error">{error}</div>}
        {mapNotice && <div className="notice">{mapNotice}</div>}

        {result && (
          <div className="legend">
            <span><i className="dash" /> fastest</span>
            <span><i className="solid" /> lower historical hazard</span>
            {result.engine === 'local' && <span className="badge">local graph</span>}
          </div>
        )}
        {result && (
          <div className="compare">
            <div className="card fast">
              <h3>Fastest route</h3>
              <div className="big">{fmtDur(fast.duration_s)}</div>
              <div>{fmtDist(fast.distance_m)}</div>
              <dl>
                <dt>Historical Hazard Exposure Index</dt><dd>{fast.historical_hazard_index ?? '—'}</dd>
                <dt>Reported pedestrian incidents within 30 m</dt><dd>{fast.nearby_reported_incidents}</dd>
              </dl>
            </div>
            <div className="card lower">
              <h3>Lower-hazard route</h3>
              <div className="big">{fmtDur(lower.duration_s)}</div>
              <div>{fmtDist(lower.distance_m)}</div>
              <dl>
                <dt>Historical Hazard Exposure Index</dt><dd>{lower.historical_hazard_index ?? '—'}</dd>
                <dt>Reported pedestrian incidents within 30 m</dt><dd>{lower.nearby_reported_incidents}</dd>
              </dl>
            </div>
            <p className="verdict">
              {result.alternative_found && result.hazard_change_percent < 0
                ? `The selected alternative has a ${Math.abs(result.hazard_change_percent).toFixed(0)}% lower Historical Hazard Exposure Index for ${fmtDur(result.extra_duration_s)} and ${fmtDist(result.extra_distance_m)} extra.`
                : 'No reasonable lower-hazard alternative was found within the 25% duration cap.'}
              <br />Data period: {result.data_period}. Model: {result.model_version}. Detour ratio: {result.detour_ratio.toFixed(3)}×.
            </p>
          </div>
        )}

        <div className="method-warning">
          Based on reported NSW pedestrian crashes from 2020–2024. This index is not a prediction or guarantee of safety. Always follow current signs, crossings and road conditions.
        </div>

        <footer>
          TfNSW reported crash data · OpenStreetMap route graph and online basemap. See Data Sources for separate attribution and licences.
        </footer>
      </div>
      <div ref={mapRef} className="map" />
    </div>
  )
}
