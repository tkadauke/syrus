# Frontend bundle analysis

The production SPA can be inspected with:

```sh
npm run build:analyze
```

This opt-in build writes an interactive treemap to `docs/bundle-analysis.html`.
The generated HTML is a local analysis artifact and is not committed.

## Baseline

Measurements use Vite's production build and gzip level 6. “Startup” is the
entry plus its transitive static imports from `.vite/manifest.json`; lazy
route chunks are excluded.

| Measurement          |       Before |       After |
| -------------------- | -----------: | ----------: |
| Entry, minified      |  3,035.57 kB | 3,034.87 kB |
| Entry, gzip          |    718.02 kB |   714.50 kB |
| Startup JS, minified | 17,880.79 kB | 5,429.03 kB |
| Startup JS, gzip     |  4,591.70 kB | 1,414.78 kB |

The analysis found that the catch-all vendor chunk made lazy dependencies
eager whenever they shared the chunk with startup code. Excalidraw and its
Mermaid/Cytoscape graph dependencies were the largest example. D3 was also
eager through the Job timeline's static import. The revised package chunks and
lazy timeline boundary remove Excalidraw, Mermaid, Cytoscape, D3, Shiki/KaTeX,
and Xterm from the entry's static imports. The startup gzip total is 69.2%
smaller; the entry itself is essentially unchanged because the improvement is
in its static dependency graph.

CI runs `npm run build && npm run check:bundle-size`. The check caps the
minified entry at 3,200,000 bytes (about 5% above this baseline).

Production sourcemaps are disabled by default. Set
`VITE_BUILD_SOURCEMAP=true` for a build that intentionally emits them.
