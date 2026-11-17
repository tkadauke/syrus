# Installing and operating external plugins

External plugins are trusted in-process code. Review their source and build
artifacts before installation. They cannot bring third-party Ruby gems; all
Ruby dependencies must already be in the Syrus bundle. Every install, upgrade,
or removal requires a restart of every web, worker, preview, setup, and other
process that boots Rails.

For authoring and packaging, see the
[external plugin authoring guide](../conventions/plugins/external-plugins.md).

## Install or upgrade

1. Build the plugin frontend before deployment and keep one complete plugin in
   one directory. Do not copy a partially built tree into the live root.
2. Put that directory under the root named by `SYRUS_PLUGIN_PATH`. The root
   contains plugin directories, not their individual `lib` directories.
3. For a multi-process or multi-worker deployment, publish the completed tree
   to a shared volume and mount the identical contents read-only into every
   Rails container. Stage an upgrade under a temporary name outside the plugin
   root, then rename or switch the shared volume atomically.
4. Run the normal Syrus deployment migration step. External `db/migrate`
   directories are included automatically, and migrations run even when the
   plugin is disabled.
5. Restart every Syrus container or native process that boots Rails. A rolling
   restart is safe only when the plugin release supports both application
   versions participating in the rollout.
6. Open **Admin → Plugins**, find the manifest name, and inspect its health,
   version, compatibility, dependencies, routes, and load diagnostics. Enable
   the plugin if it is disableable and not enabled by default, then exercise a
   representative surface.

Docker Compose sets `SYRUS_PLUGIN_PATH=/home/rails/.syrus-plugins` and mounts
the `syrus-plugins` named volume read-only in application services. The
profiled `plugin-installer` service is the only container with a writable
mount, but it is currently a placeholder rather than a registry client; use it
or another controlled one-shot container to copy a staged directory into the
volume, then recreate the whole stack. Clustered deployments should use their
normal immutable-volume or atomic shared-filesystem release mechanism.

Never let only one worker see a new plugin. Routes, providers, migrations,
frontend assets, locale files, and CLI commands are all derived at boot; mixed
plugin trees produce process-dependent behavior.

## Health and failure isolation

The Admin Plugins page is the source of truth after restart:

| State | Meaning | Operator action |
| --- | --- | --- |
| `ok` | Loaded and dependencies are satisfied | Enable and verify the plugin as needed. |
| `incompatible` | `requires_syrus` rejects the running release | Install a compatible plugin or upgrade Syrus. Plugin code did not run. |
| `failed` | Discovery or entry loading raised | Read the load failure shown on the page and container logs; fix or remove that directory. |
| `skipped_dependency` | A required plugin failed to load | Repair the named dependency first. |
| `duplicate_name` | Another installed plugin owns the same manifest name | Remove or rename the external copy; bundled plugins win collisions. |
| `degraded` | A hard dependency is absent/disabled, or a conflict is enabled | Satisfy dependencies or disable the conflict. |
| `cycle` | Hard dependencies contain a cycle | Publish corrected manifests. |

An incompatible or broken external plugin is withheld: it contributes no
providers or routes, and its engine is inert. Other plugins and core Syrus keep
booting. A frontend bundle that fails in the browser is logged and skipped
without taking down the application. These safeguards isolate failure; they do
not make unreviewed plugin code safe.

## Remove a plugin

1. Disable the plugin in **Admin → Plugins** and resolve any dependents or
   `plugin_in_use` blockers. Disabling keeps its data and migrations.
2. Back up the database and any plugin-owned external resources. If data should
   be destroyed, use the plugin's supported purge procedure before removing
   code; uninstalling alone does not roll back migrations or delete data.
3. Move the whole plugin directory out of `SYRUS_PLUGIN_PATH` atomically. Do not
   leave an empty or half-copied directory in the discovery root.
4. Restart every Rails process and confirm the plugin is absent from
   **Admin → Plugins**. Watch startup logs and verify unrelated plugins remain
   healthy.

Never manually reverse a plugin migration against a running deployment. Use a
plugin-supplied forward migration or purge contract so every application
process observes a schema its release understands.
