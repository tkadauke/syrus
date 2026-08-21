# javascript

`javascript` is a Syrus plugin gem that bundles Node/JS (and TS) prepare detection and dev-server preview hosting into a single `PluginRegistry.register` call. It lives at `plugins/javascript/` inside the Syrus repository. Named for language parity with `ruby`/`python` rather than `node`, since npm/yarn/pnpm/bun + `package.json` detection is identical for JS and TS repos.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects a Node/JS lockfile at the repo root and contributes exactly one package-manager install command, in priority order: `yarn.lock` → `pnpm-lock.yaml` → `package-lock.json` → `package.json` (`prepare_priority: 20`). |
| `:preview_provider` | Starts a preview using `package.json`'s `scripts.dev` (preferred) or `scripts.start`, the closest thing JS/TS has to a universal "how do I run this" convention. |
| `:grader_augmentor` | `JavaScript::EslintGraderAugmentor` reads ESLint's `--format json` output under `.syrus/eslint-json/` and appends compact `file:line: ruleId: message` lines to a failed grader's log when the grader command contains `"eslint"`. |

### `:preview_provider` details

- `detect?` — true when `package.json` exists and its `scripts` object defines `dev` or `start`.
- `start_command` — runs `PORT=<port> npm run <script>`, preferring `dev` over `start`. The dev/start choice is resolved at shell time (via a `node -e` one-liner reading `package.json`), not at Ruby time — preview providers are stateless between `detect?` and `start_command` calls. Most JS dev servers (Vite, webpack-dev-server, Next.js, etc.) honor `PORT`, but **this is a documented convention, not a guarantee**: some frameworks need a repo-level config change (e.g. a `server.port` option) to actually bind to the injected port. This is weaker than `.syrus.yml`'s explicit `preview:` section, where `${PORT}`/`$PORT` substitution is guaranteed by `PreviewCommandSource#from_syrus_yml` — prefer an explicit `.syrus.yml` `preview:` block for repos where port injection matters and the default script doesn't honor it.
- `setup_commands` — reuses `JavaScript::PrepareDetector.shell_install_command`, a shell-rendered version of the same `PRIORITY` lockfile table used by `:prepare_detector`, so the two extension points can never disagree about which package manager to run.
- `seed_command` — `nil`. Unlike Rails' `db:migrate` or Django's `manage.py migrate`, there's no cross-ecosystem JS convention for seeding data.
- `health_check_path` — `/` (the interface default). This is a soft guess, not a convention: JS has nothing like Rails' built-in `/up` endpoint, so a repo whose dev server 404s or redirects at `/` needs an explicit `.syrus.yml` `preview.health_check` override.
- `log_paths` / `env` / `unset_env` — left at the interface defaults (empty). No concrete need has surfaced yet for JS-specific overrides here.

## Loading the plugin

The plugin registers itself via a Rails engine `after_initialize` hook once `gem "javascript", path: "plugins/javascript"` is bundled — no manual `register!` call needed.

## Running tests

From the repo root:

```
bin/rspec spec/plugins/javascript/
```
