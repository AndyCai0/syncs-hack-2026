# Data sources, attribution and licences

The code licence and each data/map licence are separate. The repository owner still needs to approve a code licence before submission.

## NSW Road Crash Data

- Dataset: NSW Road Crash Data, CRASH and TRAFFIC UNIT tables
- Custodian: Transport for NSW
- Source: [TfNSW Open Data — NSW Crash Data](https://opendata.transport.nsw.gov.au/dataset/nsw-crash-data)
- Data used by the model: 2020–2024 only
- Upstream page status checked: 29 August 2026; the dataset page reports an update on 9 October 2025
- Repository snapshot: committed 29 August 2026
- Licence: Creative Commons Attribution, as stated on the TfNSW dataset/resource pages
- Use: severity, time/light conditions, speed-limit field, crash coordinates, and pedestrian involvement joined by crash ID
- Limitations: reported incidents only; coordinates and classifications may contain errors; the supplied files contained a small number of 2019 records, which the pipeline and runtime explicitly exclude

## NSW School Zones

- Dataset: Speed Zones — School Zones
- Custodian: Transport for NSW
- Source: [TfNSW Open Data — School Zones](https://opendata.transport.nsw.gov.au/data/dataset/speed-zones/resource/b6d7d02c-5625-461c-8b44-bba1a6ef3e0f)
- Data period: current network snapshot; individual historical validity is not modelled
- Upstream page status checked: 29 August 2026; the resource page reports an update on 2 August 2026
- Repository snapshot: committed 29 August 2026
- Licence: Creative Commons Attribution, as stated on the resource page
- Use: explanatory polygons and source operating-time fields
- Limitations: routing stores only an intersection boolean and does not apply a safety discount or time-aware school-zone rule

## NSW Public Schools Master Dataset

- Dataset: NSW public schools master dataset
- Custodian: NSW Department of Education / Data.NSW
- Source: [Data.NSW — NSW public schools master dataset](https://data.nsw.gov.au/data/dataset/nsw-education-nsw-public-schools-master-dataset/resource/3e6d5f6a-055c-440d-a690-fc0537c31095)
- Data period: current snapshot rather than a crash-history period
- Upstream page status checked: 29 August 2026; the resource page reports an update on 2 August 2026
- Repository snapshot: committed 29 August 2026
- Licence: Creative Commons Attribution, as stated on the resource page
- Use: school names, attributes and approximate destination points
- Limitations: a school coordinate is not assumed to be a pedestrian entrance

## OpenStreetMap route graph

- Dataset: OpenStreetMap data, Greater Sydney extract
- Custodian: OpenStreetMap contributors
- Source provider: [Geofabrik Australia and Oceania extracts](https://download.geofabrik.de/australia-oceania.html)
- Local extract vintage: `UNKNOWN`; the repository snapshot was committed 29 August 2026
- Licence and required attribution: [OpenStreetMap copyright and ODbL](https://www.openstreetmap.org/copyright)
- Use: walking and retained experimental cycling graph topology and geometry
- Limitations: coverage and tags vary; the public model treats the walking graph as undirected and does not independently verify every path

## Online basemap

- Service: OpenStreetMap standard raster tile service
- Attribution shown in the map: `© OpenStreetMap contributors`
- Data licence: ODbL; service operation is additionally governed by the [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- Use: interactive background map only; no bulk download, prefetch or offline packaging
- Limitations: requires network access and is not guaranteed. Local route computation and deterministic Demo Cases do not require it

## Optional place search

The web app proxies interactive queries to the public Photon service with a Sydney location bias. It does not commit geocoder results and is not required for the Demo Cases. Availability and result quality are outside this repository's control.
