# Authoring an external plugin

An external plugin is a trusted Rails Engine loaded into the Syrus process from
a directory outside the Syrus repository. It uses the same plugin API as a
bundled plugin, but it must be self-contained: external plugins cannot add gems
to the already-resolved Syrus bundle. Audit all plugin code before installing
it; it runs with the same process and database access as Syrus. Installing,
upgrading, or removing one requires restarting every process that boots Rails.

The continuously tested minimal example is
[`spec/fixtures/relocatable_plugin`](../../../../spec/fixtures/relocatable_plugin/).
`bin/test-plugin-relocation` copies that directory outside the checkout and
proves its provider, route, migration, frontend, and CLI command all work.

## Directory layout

```text
my_plugin/
├── my_plugin.gemspec
├── lib/my_plugin.rb
├── app/
│   ├── controllers/api/v1/app/my_plugin/...
│   └── services/my_plugin/...
├── db/migrate/20261117000000_create_my_plugin_records.rb
├── frontend/
│   ├── entry.tsx
│   └── style.css
├── app/frontend/i18n/locales/
│   ├── en/my_plugin.json
│   ├── de/my_plugin.json
│   └── la/my_plugin.json
└── dist/frontend/                 # generated and shipped
    ├── plugin.js
    ├── plugin.css
    └── manifest.json
```

The directory name, gemspec basename, gem name, entry file, and manifest name
should agree. The gemspec must declare only dependencies already supplied by
Syrus (normally Rails) and may set compatibility metadata:

```ruby
Gem::Specification.new do |spec|
  spec.name = "my_plugin"
  spec.version = "0.1.0"
  spec.summary = "An example Syrus plugin"
  spec.authors = [ "Example author" ]
  spec.files = []
  spec.add_dependency "rails", ">= 8.1"
  spec.metadata["requires_syrus"] = ">= 0.1.16"
end
```

`requires_syrus` is a Ruby `Gem::Requirement`. Set it to the oldest Syrus
release the plugin has actually been tested against. An unsatisfied requirement
marks the plugin `incompatible` before any plugin code executes.

`lib/my_plugin.rb` declares the runtime contract:

```ruby
module MyPlugin
  extend Syrus::PluginApi

  syrus_plugin "my_plugin" do
    depends_on [ "another_plugin" ]
    provides callbacks: "MyPlugin::Callbacks"

    route :get, "/api/v1/app/my_plugin/ping",
          to: "api/v1/app/my_plugin/ping#show"

    frontend bundle: "dist/frontend/plugin.js",
             css: "dist/frontend/plugin.css",
             i18n: [ "app/frontend/i18n/locales/*/my_plugin.json" ]

    cli_commands [
      {
        path: %w[my-plugin ping],
        summary: "Check the plugin",
        handler: "MyPlugin::Cli::Ping"
      }
    ]
  end

  class Callbacks; end
end
```

`depends_on`, `optionally_depends_on`, and `conflicts_with` name other manifest
names. `provides` maps an extension-point name to a lazily resolved class name;
use only extension points listed in the [full authoring reference](authoring.md).
`route` declarations are installed into the plugin engine. Migrations are
discovered by convention from `db/migrate` and run with the normal Syrus
deployment migrations, whether the plugin is enabled or disabled.

Locale patterns belong inside `frontend`. English is required; German and
Latin should carry the same key tree. `cli_commands` handlers subclass
`Syrus::Plugin::CliCommandHandler`, authorize the authenticated user, and
return table, text, or JSON results. See the full authoring reference for
argument and flag declarations.

## Build the frontend

From a Syrus checkout whose JavaScript dependencies are installed, run:

```sh
bin/build-plugin-frontend /absolute/path/to/my_plugin
```

The script builds the conventional `frontend/entry.tsx` into the three files
under `dist/frontend`. Commit or package those generated files with the plugin;
the running Syrus instance does not compile external source.

The bundle may import only these modules from the host:

- `react`, including `react/jsx-runtime`
- `react-dom`, including `react-dom/client`
- `@tanstack/react-query`
- `i18next`
- `react-i18next`
- `@syrus/plugin-sdk`

The build script externalizes those modules so the plugin shares the host's
runtime. Every other frontend dependency is bundled by the plugin. Import the
plugin's stylesheet from `entry.tsx`; plugins ship complete CSS and cannot rely
on Syrus compiling Tailwind classes from external source.

Register UI components with `registerPluginContribution` from
`@syrus/plugin-sdk`. The manifest's `frontend` paths are relative to the plugin
root. Syrus serves only declared files and advertises assets only while the
plugin is enabled and healthy.

## Validate before distribution

Use the fixture as an executable shape, then test the plugin from an external
root rather than from `plugins/`:

```sh
SYRUS_PLUGIN_PATH=/absolute/path/to/plugin-root \
  RAILS_ENV=test bin/rails runner 'abort unless Syrus::PluginRegistry.health.healthy?("my_plugin")'
```

Also exercise every declared route and CLI handler, apply migrations to a
disposable database, and load the built bundle in a browser. The plugin
relocation acceptance test is the repository's reference for those checks.

Installation and removal are covered by the
[external plugin operations runbook](../../operations/external-plugins.md).
