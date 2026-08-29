# SafeRoutes Sydney web client

React, Vite and MapLibre frontend for the walking-only hackathon demo.

From the repository root:

```bash
npm --prefix frontend ci
npm --prefix frontend run dev
```

The development server proxies `/api` to `http://127.0.0.1:8000`. Start the FastAPI backend first, or use `./scripts/dev.sh` to start both services.

```bash
npm --prefix frontend run lint
npm --prefix frontend run build
```

The deterministic demo buttons use committed coordinates and do not need the optional Photon place search. The online OpenStreetMap tile layer still requires network access; local routing continues to work if the background map is unavailable.
