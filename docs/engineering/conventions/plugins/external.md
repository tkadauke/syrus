# Authoring an external plugin

An external plugin is a trusted Rails Engine gem stored outside the Syrus
repository. Syrus discovers it from `SYRUS_PLUGIN_PATH`, loads it in the Rails
process, and serves its prebuilt browser assets. External plugins are not a
sandbox: install only code you trust with the same data and credentials as the
Syrus process.

For every extension-point interface and lifecycle hook, see the full
[plugin-authoring reference](authoring.md). The generated
[host API reference](host-api.md) lists the supported core surface, while the
[single-file plugin specification](plugin-spec.md) is the compact, complete
contract intended for an LLM context. The tested
[`relocatable_plugin`](../../../../spec/fixtures/relocatable_plugin/)
fixture is the smallest end-to-end example. `bin/test-plugin-relocation`
copies it outside the checkout and proves its provider, route, migration,
frontend bundle, and CLI command still work there.

## Directory layout

Each immediate child of the external root is one plugin. A useful minimum is:

```text
weather_tools/
├── weather_tools.gemspec
├── lib/weather_tools.rb
├── app/
│   ├── controllers/...
│   ├── models/...
│   └── services/...
├── db/migrate/20261117000000_create_weather_tools_reports.rb
├── frontend/
│   ├── entry.tsx
│   └── style.css
└── dist/frontend/                 # generated; ship this directory
    ├── plugin.js
    ├── plugin.css
    └── manifest.json
```

The directory must contain exactly one gemspec. Its gem name determines the
entry filename at `lib/<gem-name>.rb`; that file must declare exactly one
`syrus_plugin` definition. Plugin table names must use the plugin namespace.
Locale files, when present, use
`app/frontend/i18n/locales/<language>/<namespace>.json`; English is required,
and user-visible bundled UI must supply matching German and Latin translations.

External gemspecs may depend only on `rails`. Syrus does not install arbitrary
third-party gems for a dropped-in plugin. Bundle any browser dependencies into
the frontend output, and implement Ruby integrations using Rails, Ruby's
standard library, and Syrus's public plugin contracts.

```ruby
Gem::Specification.new do |spec|
  spec.name = "weather_tools"
  spec.version = "1.0.0"
  spec.summary = "Weather tools for Syrus"
  spec.authors = [ "Example author" ]
  spec.files = []
  spec.add_dependency "rails", ">= 8.1"
  spec.metadata["requires_syrus"] = ">= 0.1.16"
end
```

`requires_syrus` is a Ruby `Gem::Requirement`. Set it to the oldest Syrus
release the plugin is tested against. An unsatisfied requirement prevents the
plugin code from running and reports it as incompatible; an invalid requirement
reports a load failure.

## Manifest

The entry file extends `Syrus::PluginApi`. This example shows the relocation-
relevant declarations; omit surfaces the plugin does not provide.

```ruby
module WeatherTools
  extend Syrus::PluginApi

  syrus_plugin "weather_tools" do
    version "1.0.0"
    depends_on "repository_content"
    optionally_depends_on "metrics"

    provides repository_content_provider: "WeatherTools::ContentProvider"

    route :get, "/api/v1/app/weather_tools/forecast",
          to: "api/v1/app/weather_tools/forecasts#show"

    frontend(
      bundle: "dist/frontend/plugin.js",
      css: "dist/frontend/plugin.css",
      i18n: [ "app/frontend/i18n/locales/*/weather_tools.json" ]
    )

    cli_commands [
      {
        path: %w[weather forecast],
        summary: "Show the current forecast",
        handler: "WeatherTools::Cli::Forecast",
        arguments: [ { name: "place", type: :string, required: true } ],
        flags: [ { name: "days", type: :integer, default: 1 } ]
      }
    ]
  end
end
```

- `depends_on`, `optionally_depends_on`, and `conflicts_with` take manifest
  names, not gem names. Hard dependencies must be installed and healthy before
  the plugin contributes runtime behavior.
- `provides` maps extension-point names to class-name strings. Classes are
  resolved after plugin autoload paths exist; consult the authoring reference
  for the interface of each extension point.
- `route` declarations are mounted by the plugin engine. Controllers live
  under the plugin's `app/controllers` tree and normal authentication and
  authorization rules still apply.
- `db/migrate` is automatically added to the primary migration paths. Migrations
  run during the normal deployment migration phase, whether the plugin is
  enabled or disabled; enabling a plugin never runs migrations.
- `frontend` paths are relative to the plugin root. `bundle` is required for a
  browser contribution; `css` and `i18n` are optional. English locale JSON is
  the runtime fallback when another declared language is missing or fails.
- `cli_commands` declares non-interactive server-backed commands. Each command
  has a word-array `path`, one-line `summary`, handler class, and optional typed
  `arguments` and `flags`. Handlers subclass
  `Syrus::Plugin::CliCommandHandler`, authorize the authenticated user, and
  return a table, text, or JSON result. Use a separately distributed
  `syrus-<name>` executable for commands that need local files, prompts,
  streaming, or child processes.

## Build the frontend

Create `frontend/entry.tsx`, import the plugin's own stylesheet, and register
components through `@syrus/plugin-sdk`:

```tsx
import React from "react"
import { registerPluginContribution } from "@syrus/plugin-sdk"
import "./style.css"

const Forecast = () => <section className="weather-tools">Forecast</section>

registerPluginContribution(
  "workspace_tab",
  "weather_tools",
  "Forecast",
  { default: Forecast },
)
```

From a Syrus checkout with its JavaScript dependencies installed, run:

```bash
bin/build-plugin-frontend /path/to/weather_tools
```

The build writes `dist/frontend/plugin.js`, optional `plugin.css`, and the
frontend manifest. A bundle may import only these host-shared modules:

- `react` and its subpaths, including `react/jsx-runtime`
- `react-dom` and its subpaths, including `react-dom/client`
- `@tanstack/react-query`
- `i18next`
- `react-i18next`
- `@syrus/plugin-sdk`

The builder externalizes those modules so the plugin and host share one
runtime. All other JavaScript dependencies are bundled into `plugin.js`.
Plugins ship complete CSS; Syrus does not scan external source for Tailwind
classes or compile plugin styles.

## Validate the package

Run the plugin's own tests, then exercise the host boundary. The repository's
fixture demonstrates the expected packaging and assertions:

```bash
bin/build-plugin-frontend /path/to/weather_tools
bin/test-plugin-relocation
```

The second command validates Syrus's maintained example rather than an
arbitrary path. Plugin projects should mirror that acceptance coverage for
their own manifest and surfaces before distributing the directory.

Installation and rollback are operator procedures; see
[External plugin operations](../../operations/external-plugins.md).
