# External plugin operations

External plugins are trusted, in-process code. Installing one gives it the same
database, filesystem, network, and credential access as Syrus. Review its source
and obtain it through a trusted channel before placing it on an instance.

## Desired-state storage and signatures

The control plane stores external release archives in the primary Active
Storage service. Archives use the content-addressed object key
`plugins/artifacts/<sha256>`. The declared SHA-256 digest and byte size are
checked before the archive is attached to a release.

The desired set is published for pre-boot readers at:

- `plugins/desired/manifest.json`
- `plugins/desired/manifest.json.sig`

The JSON contains schema version `1`, a monotonically increasing revision, and
the enabled external (non-bundled) releases with their name, version, SHA-256 digest, byte
size, process roles, and fleet-quarantine state. Publication writes the
detached signature before atomically replacing the manifest, so the manifest
is the commit point. Readers must verify the signature over the manifest's
exact bytes before parsing or acting on it. A verification failure, unknown
schema version, missing artifact, size mismatch, or digest mismatch makes the
publication unusable. Bundled releases ship in the Syrus image, are never
published, and are excluded from fleet convergence; an installation with no
enabled external releases never raises the plugin fleet divergence alert.

Generate the control-plane Ed25519 key once with
`bin/rails plugin_manifest:keygen`. The private seed is encrypted in the
singleton application settings record. Distribute the command's base64 public
key to every pre-boot sync process as `SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY`; never
distribute the private seed. The control plane refuses publication when that
configured public key does not match its stored private key. Back up the
encrypted application setting with the database and treat key rotation as a
coordinated configuration rollout.

The plugin package is one directory containing its gemspec, Ruby entry file,
application code, migrations, and any prebuilt frontend assets. Plugin authors
can follow [Authoring an external plugin](../conventions/plugins/external.md).

## Prepare the shared root

Set `SYRUS_PLUGIN_PATH` to a directory whose immediate children are plugin
directories. Every process that boots Rails must see identical contents at the
same path: web, workers, setup/migration jobs, preview processes, and any other
Rails service. In a multi-container deployment, mount one shared volume
read-only into those containers and reserve write access for the deployment or
installation mechanism.

Docker Compose already mounts its `syrus-plugins` named volume read-only at
`/home/rails/.syrus-plugins` and sets `SYRUS_PLUGIN_PATH` to that location. Its
`plugin-installer` profile is only a writable placeholder; there is no registry
or installer workflow yet. Populate the volume through an operator-controlled
helper container or volume-management procedure while the application is
stopped. Kubernetes deployments should provide the equivalent shared,
read-only application mount through their normal storage and rollout system.
The shipped k3s workloads continue to use plugins baked into the image; when
no signed desired-state storage is configured, the shared entrypoint's sync is
a no-op. Third-party plugin distribution to k3s and native macOS workers
remains outside this mechanism.

## Install or replace a plugin

1. Verify the directory has exactly one gemspec, `lib/<gem-name>.rb`, and any
   referenced `dist/frontend` assets. Do not run Bundler: external plugins may
   depend only on Rails and are discovered independently of the application
   bundle.
2. Stage the complete directory beside the shared root. Do not copy individual
   files into the live directory while containers can read it.
3. Stop every Syrus container or otherwise prevent Rails processes from booting
   during the swap. Rename the staged directory into the root atomically; when
   upgrading, rename the old directory aside first so rollback remains
   available.
4. Run the deployment's normal database migration phase with the shared root
   mounted and `SYRUS_PLUGIN_PATH` set. Syrus automatically includes every
   discovered plugin's `db/migrate` directory. Migrations run even when the
   plugin is disabled.
5. Restart every Rails container, including web, workers, setup/migration,
   preview, and auxiliary Rails processes. Installation, upgrades, and removal
   are boot-time changes; restarting only web can leave different processes
   running different plugin code.
6. Open **Admin → Plugins**, find the manifest name, and check its version,
   enabled state, health, dependencies, extension points, routes, and load
   failures. Enable the plugin there if it is disableable and was installed
   disabled. Exercise one plugin-owned surface or command after enablement.

Keep the previous directory until the application is healthy. A frontend
bundle or locale failure is isolated in the browser, but it still means that
plugin UI is unavailable and should be investigated before completing rollout.

## Interpret health states

- `incompatible` means `requires_syrus` excludes the running release. Syrus
  does not execute the plugin. Upgrade Syrus or install a compatible plugin
  release; do not weaken the requirement without compatibility testing.
- `failed` means discovery or plugin loading raised an error. The admin detail
  page retains the failure and backtrace. Syrus makes that plugin's engine
  inert and withholds its routes and providers while continuing to load other
  plugins.
- `skipped_dependency` means a required plugin failed or was not loaded. Repair
  the dependency first.
- `duplicate_name` means two external directories declare the same manifest
  identity. A built-in plugin also wins a collision with an external copy.
  Remove or rename the external package rather than expecting load order to
  choose one.
- `degraded` and `cycle` describe runtime dependency or conflict problems.
  The plugin stays installed but its contributions are withheld until its
  dependency graph is healthy.

The failure shown in **Admin → Plugins** is the first diagnostic source. Then
inspect startup logs from each process type: one container may have a stale
mount or may not have restarted even when another reports the plugin healthy.
A broken external plugin should not prevent Syrus from booting; if the plugin
is absent from the inventory entirely, verify the shared path, gemspec and entry
filename, permissions, and `SYRUS_PLUGIN_PATH` in that process.

## Remove or roll back a plugin

First disable the plugin in **Admin → Plugins** and resolve any in-use blockers.
Disabling withholds behavior but retains data and does not unload code from
already-running processes.

To uninstall, stop every Syrus container, move the plugin directory out of the
shared root, and restart every container. Do not reverse or delete its
migrations as part of ordinary uninstall: retained tables and records make a
reinstall or rollback possible. To roll back code, atomically restore the saved
compatible directory and perform the same full restart. Destructive data purge
is a separate, explicit procedure governed by the plugin's ownership manifest;
preview it before confirming it.
