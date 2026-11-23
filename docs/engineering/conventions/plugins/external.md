# Build, test, and install an external plugin

This guide starts with an empty directory and ends with a plugin that can be
installed by hand. External plugins are trusted Rails Engine gems: they run in
the Syrus process with its database, filesystem, network, and credentials.
Review a plugin before installing it.

## The one rule about core

Plugin Ruby may reference only:

- public `Syrus::Host::*` APIs;
- `Syrus::PluginApi`, the plugin DSL, and documented plugin interface modules;
- the plugin's own code; and
- Rails, the Ruby standard library, and the plugin's permitted gems (currently
  only Rails for a dropped-in external plugin).

Every other Syrus core constant is internal and may change without notice. Do
not copy a bundled plugin's internal reference into an external plugin.

As part of `syrus plugin validate`, the host-surface scanner inspects Ruby
without executing it; the validation command later boots the plugin to check
its runtime contracts. A direct reference to an unsupported core constant is
an error. A legacy, non-public constant is a warning from the scanner but fails
the external-plugin host contract; replace it rather than shipping it. Literal
core names passed to `class_name`,
`constantize`, `safe_constantize`, or `const_get` produce warnings because
static analysis cannot prove what they resolve to. Computed strings cannot be
detected.

The validator also reports the minimum Syrus version implied by the newest
`since` declaration among the `Syrus::Host` APIs the plugin uses. Set
`requires_syrus` to the oldest release actually tested, but never below that
derived floor. If a capability is missing from `Syrus::Host`, ask Syrus to add
a small public facade. Do not reach around the public surface.

The generated [host API reference](host-api.md) is the supported core catalog.
The generated [single-file plugin specification](plugin-spec.md) is the compact
complete contract, suitable for giving to an LLM. The longer
[plugin-authoring reference](authoring.md) documents every extension point and
lifecycle hook.

## 1. Generate a plugin

Install a current `syrus` CLI and Docker, then run:

```console
$ syrus plugin new weather_tools --syrus-version 1.2.3
Created weather_tools
Run: cd weather_tools && syrus plugin test .
$ cd weather_tools
```

Normally omit `--syrus-version`: the generator uses the connected instance's
release, then the CLI release as a fallback. The explicit version makes this
example reproducible. The name must be lower-case snake case. The destination
must be absent or empty; use `--path DIR` to put it elsewhere.

The baseline scaffold contains a callback provider, matching English, German,
and Latin locales, a prebuilt empty frontend bundle, an RSpec host-contract
spec, and CI that runs `syrus plugin test .`. Add examples only when useful:

```console
$ syrus plugin new weather_tools --frontend --model --cli
```

`--frontend` adds an admin-page component and its source, `--model` adds a
namespaced record and migration, and `--cli` adds a server-backed command.

## 2. Develop against a real host

From the generated directory, start the disposable development host:

```console
$ syrus plugin dev .
Plugin development instance: http://127.0.0.1:<port>
Sign in with demo@syrus.local / password
```

Open the printed URL. Ruby, manifest, and locale edits restart the host;
frontend edits rebuild the bundle. The loop prints plugin health after each
reload. Press Ctrl-C to stop it. Its SQLite data is discarded unless you pass
`--keep-data`. This host has no production data or agent credentials.

## 3. Validate, then run the tests

Validation boots the plugin against a release-matched Syrus test host and
checks discovery, the manifest, compatibility, public-host usage, frontend
hashes, and locale parity:

```console
$ syrus plugin validate . --syrus-version 1.2.3 --json
{"version":1,"mode":"validate","plugin":"weather_tools","validation":"passed","tests":"not_run","exit_code":0}
```

Then run the same validation followed by the plugin's RSpec suite:

```console
$ syrus plugin test . --syrus-version 1.2.3 --json
{"version":1,"mode":"test","plugin":"weather_tools","validation":"passed","tests":"passed","exit_code":0}
```

Without `--json`, RSpec output is printed before the same summary. Both
commands default to the current directory and choose the connected instance's
release, or the CLI release when disconnected. They pull the matching
`ghcr.io/tkadauke/syrus-plugin-test` image and mount only the plugin directory;
credentials are not passed into the container. Syrus contributors may use
`--checkout /path/to/syrus` to run the identical test entrypoint locally.

Commit the generated `dist/frontend` files. A plugin is not ready to distribute
until `syrus plugin test` succeeds from the packaged directory.

## 4. Install it by hand

Follow [External plugin operations](../../operations/external-plugins.md). In
short: stage the complete directory, stop every Rails process, atomically move
the directory under the shared `SYRUS_PLUGIN_PATH`, run normal deployment
migrations, and restart every Rails process. Inspect **Admin → Plugins** before
enabling it. Installation and rollback are boot-time operator procedures; do
not copy files into a live plugin directory one at a time.

## Write a plugin with an LLM

Give the model one contract file: [the single-file plugin
specification](plugin-spec.md). Add existing plugin files only when asking it
to modify them. A useful prompt is:

```text
Goal: <the user-visible capability>

Constraints:
- Follow the attached Syrus external-plugin specification.
- Reference only Syrus::Host APIs, the plugin DSL and documented interface
  modules, this plugin's code, Rails, and the Ruby standard library.
- Keep every file inside the plugin and add no runtime gem except Rails.

Implement the plugin behavior and its RSpec coverage. The finished package
must pass: syrus plugin test .
```

Run `syrus plugin test .` after each small change. Give the model the complete
failing matcher or scanner output, ask it to fix that failure without relaxing
the spec, and rerun. The final JSON summary must report both validation and
tests as `passed`.

## Package reference

Each immediate child of `SYRUS_PLUGIN_PATH` is one plugin and contains exactly
one gemspec. The gem name determines `lib/<gem-name>.rb`; that entry file
declares exactly one `syrus_plugin` definition. A generated baseline looks like:

```text
weather_tools/
├── weather_tools.gemspec
├── lib/weather_tools.rb
├── app/services/weather_tools/callbacks.rb
├── app/frontend/i18n/locales/{en,de,la}/weather_tools.json
├── dist/frontend/{plugin.js,manifest.json}
├── spec/weather_tools_spec.rb
└── .github/workflows/test.yml
```

Plugin tables and Ruby constants must use the plugin namespace. `db/migrate`
is added to normal deployment migrations whether the plugin is enabled or
disabled. External gemspecs may depend only on Rails; bundle browser
dependencies into the frontend output.

The scaffold's manifest uses only valid DSL keys:

```ruby
module WeatherTools
  extend Syrus::PluginApi

  syrus_plugin "weather_tools" do
    version "0.1.0"
    display_name "Weather Tools"
    category "tooling"
    author "Your name"
    description "Weather Tools plugin for Syrus."
    provides callbacks: "WeatherTools::Callbacks"
    surface admin_pages: "WeatherTools::AdminPages"
    frontend bundle: "dist/frontend/plugin.js",
             i18n: [ "app/frontend/i18n/locales/*/weather_tools.json" ]
  end
end
```

`depends_on`, `optionally_depends_on`, and `conflicts_with` name plugin
manifests. `provides` maps a registered extension point to a class-name string,
resolved after autoload paths exist. `route` mounts a plugin controller.
`frontend` paths are relative to the plugin root. `cli_commands` declares
non-interactive server-backed commands whose handlers subclass
`Syrus::Plugin::CliCommandHandler`. Consult the generated plugin specification
for the complete key list and extension-point contracts.

Browser surfaces are declared with the `surface` helper using class-name
strings (`admin_pages`, `sidebar_pages`, `repo_page_tabs`, `workspace_tabs`,
`ui_slots`, `artifact_renderers`, or provisional `preview_panel_viewers`). The
declaration is manifest data and does not import the frontend bundle or load
plugin application constants. The bundle separately registers its React
components at runtime as described below.

For a real browser contribution, create `frontend/entry.tsx`, register it with
`registerPluginContribution` from `@syrus/plugin-sdk`, and run:

```console
$ bin/build-plugin-frontend /path/to/weather_tools
```

The build writes `dist/frontend/plugin.js`, optional `plugin.css`, and
`manifest.json`. It shares the host's React, React DOM, TanStack Query, i18next,
react-i18next, and `@syrus/plugin-sdk`; all other JavaScript dependencies are
bundled. Ship complete CSS because Syrus does not compile an external plugin's
Tailwind source.

## Troubleshooting actual validation failures

### Incompatible Syrus version

`expected weather_tools requires_syrus >= 1.2.3 to accept running Syrus 1.1.0`
means the selected host is older than the gemspec requirement. Test against a
newer host, or support and test the older release before lowering the
requirement. Never lower it beneath the scanner's `Minimum Syrus version`.

### Non-public or unsupported host API

`expected weather_tools host-surface scan to be clean; ... legacy=[...]` means
the plugin uses a known legacy constant; `unsupported=[...]` means it uses an
internal constant. Scanner lines label these `NON-PUBLIC` and `UNLISTED`.
Replace the reference with a host facade. `DYNAMIC` identifies a literal string
reference that requires manual review. Ask for a facade when no public API can
express the capability.

### Missing locale key

`expected weather_tools locale files in en, de, and la with matching keys;
mismatched keys for weather_tools: ...` means the locale JSON key sets differ.
Add the same key to all three files. A diagnostic such as `de/weather_tools`
instead means that language file is absent or did not match `frontend.i18n`.

### Frontend bundle hash mismatch

`expected weather_tools to have a frontend bundle whose hash matches
bootstrap; entry=..., computed_hash=...` means `plugin.js` or `plugin.css`
changed without a matching generated manifest, or the manifest points at the
wrong file. Re-run the frontend builder and commit the complete
`dist/frontend` output.

### Load failure

`expected weather_tools to be loaded from ... but manifest was nil` means
discovery or entry-file evaluation failed. Check that there is exactly one
gemspec, its name maps to `lib/weather_tools.rb`, the entry declares one
matching `syrus_plugin`, and Ruby syntax is valid. The non-JSON runner output
and **Admin → Plugins** retain the underlying exception and backtrace; repair
that first rather than masking the load check.
