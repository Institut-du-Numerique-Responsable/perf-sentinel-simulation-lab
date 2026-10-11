# Deployment-mode architecture diagrams

Standalone Mermaid sources (`mmd/`) and rendered SVGs (`svg/`), one per
scenario. The same diagrams are embedded as fenced code blocks in
`../SCENARIOS.md` so the guide renders self-contained on GitHub. These
`.mmd` files are kept separate so they can be:

- Edited in a Mermaid-aware editor (VS Code Mermaid extension, IntelliJ
  Mermaid plugin, mermaid.live).
- Rendered to SVG/PNG offline for slide decks or external docs.
- Promoted into the upstream
  [perf-sentinel](https://github.com/Institut-du-Numerique-Responsable/perf-sentinel) docs
  without carrying the lab's surrounding markdown.

## Layout

```
docs/diagrams/
├── mmd/                       # Mermaid sources (single editable copy)
│   ├── global-integration.mmd
│   ├── hybrid-daemon-batch.mmd
│   └── ...
└── svg/                       # Rendered artifacts (committed, used by docs)
    ├── global-integration.svg
    └── ...
```

A single SVG per diagram. Colors and contrast are baked into the
`.mmd` source so the rendered SVG stays readable in both light and
dark mode without needing a `<picture>` theme switcher.

A guide embeds a diagram via a plain markdown image:

```markdown
![Alt text](https://raw.githubusercontent.com/Institut-du-Numerique-Responsable/perf-sentinel-simulation-lab/main/docs/diagrams/svg/global-integration.svg)
```

URLs are absolute (`raw.githubusercontent.com/...`) so the same
markdown renders correctly when copied into other repos or external
sites.

## Files

| `.mmd` source | Scenario |
| --- | --- |
| `mmd/global-integration.mmd` | 10000-foot view: perf-sentinel across local dev, CI, staging, prod |
| `mmd/hybrid-daemon-batch.mmd` | hybrid daemon -> batch HTML |
| `mmd/batch-tempo-scrape.mmd` | batch over Tempo |
| `mmd/daemon-otlp-direct.mmd` | daemon OTLP direct (no Collector) |
| `mmd/multiformat-input.mmd` | multi-format input (Jaeger + Zipkin) |
| `mmd/calibrate-mode.mmd` | calibrate energy coefficients |
| `mmd/sidecar-pattern.mmd` | sidecar pattern |
| `mmd/correlation-finding.mmd` | cross-trace correlation finding |
| `mmd/pg-stat.mmd` | `report --pg-stat` live integration |

## Render to SVG locally

Single file:

```bash
npx -y @mermaid-js/mermaid-cli -i mmd/global-integration.mmd \
  -o svg/global-integration.svg -t default -b transparent
```

Or batch all scenarios:

```bash
for f in mmd/*.mmd; do
  base=$(basename "$f" .mmd)
  npx -y @mermaid-js/mermaid-cli -i "$f" -o "svg/${base}.svg" -t default -b transparent
done
```

## Visual vocabulary

- Solid arrow = always-on flow (production traffic, OTLP, pull loops).
- Dashed arrow = on-demand fetch (CI snapshot, CLI batch, query API).
- Box with double border (`[[ ... ]]`) = perf-sentinel surface (CLI
  subcommand or daemon endpoint).
- Blue stroke = `classDef sentinel` styling, applied to every
  perf-sentinel node for at-a-glance recognition. Fill is set
  explicitly in the `.mmd` source so contrast stays correct in both
  light and dark mode.
