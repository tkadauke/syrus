# This file runs in a fresh Rails process from bin/test-plugin-relocation. It
# deliberately exercises boot-time paths that cannot be reset safely in the
# main RSpec process.
require "json"

def assert!(condition, message)
  raise message unless condition
end

expected_root = Pathname.new(ENV.fetch("RELOCATABLE_PLUGIN_ROOT")).realpath
assert!(!Syrus::PluginRoots.default.built_in_root.join("relocatable_plugin").exist?, "fixture leaked into the built-in plugin root")
manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "relocatable_plugin" }
assert!(manifest&.loaded, "external plugin was not loaded")
assert!(Pathname.new(manifest.plugin_root).realpath == expected_root, "plugin did not load from the external root")
assert!(Syrus::PluginRegistry.health.status("relocatable_plugin").healthy?, "external plugin health is not healthy")
assert!(Syrus::PluginRegistry.providers_for(:callbacks).include?(RelocatablePlugin::Callbacks), "provider was not registered")
assert!(Syrus::PluginRegistry.providers_for(:backup_destination).include?(RelocatablePlugin::BackupDestination), "backup destination capability was not relocated")
assert!(RelocatablePlugin::BackupDestination.compatible_contract?(1), "relocated backup destination does not implement contract v1")
incompatible = Syrus::PluginRegistry.health.status("future_plugin")
assert!(incompatible&.state == :incompatible, "newer requires_syrus plugin was not reported incompatible")
assert!(!Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "future_plugin" }.loaded, "incompatible plugin loaded")
failed = Syrus::PluginRegistry.health.status("exploding_plugin")
assert!(failed&.state == :failed, "raising plugin was not isolated as failed")
assert!(manifest.loaded, "a raising neighbor prevented the healthy plugin from loading")

migration_path = expected_root.join("db/migrate").to_s
# Compare resolved paths: on macOS the temp root is /var/..., a symlink to
# /private/var/..., and Rails keeps the path it was given.
resolved = ->(paths) { paths.map { |path| File.exist?(path) ? File.realpath(path) : path } }
assert!(resolved.(Rails.application.paths["db/migrate"].to_a).include?(migration_path), "external migration path is absent")
assert!(resolved.(ActiveRecord::Migrator.migrations_paths).include?(migration_path), "migrator does not include the external path")
migration = ActiveRecord::MigrationContext.new([ migration_path ])
migration.migrations.each { |candidate| migration.schema_migration.delete_version(candidate.version.to_s) }
migration.up
assert!(ActiveRecord::Base.connection.table_exists?(:relocatable_plugin_probes), "external migration did not apply")

user = User.create!(email_address: "relocation-#{SecureRandom.hex(4)}@example.com", password: "supersecret")
session = ActionDispatch::Integration::Session.new(Rails.application)
session.post("/session", params: { email_address: user.email_address, password: "supersecret" })

session.get("/api/v1/app/relocatable_plugin/ping")
assert!(session.response.status == 200, "external plugin route did not respond")
assert!(JSON.parse(session.response.body).fetch("location") == "external", "external plugin route returned the wrong payload")

session.get("/api/v1/app/cli_commands")
catalog = JSON.parse(session.response.body).fetch("commands")
assert!(catalog.any? { |command| command["plugin"] == "relocatable_plugin" && command["path"] == %w[relocation ping] }, "CLI catalog omitted the external command")
session.post("/api/v1/app/cli_commands/execute", params: { plugin: "relocatable_plugin", path: %w[relocation ping] }, as: :json)
assert!(session.response.status == 200, "external CLI command endpoint failed")
assert!(JSON.parse(session.response.body).dig("result", "text").include?(user.email_address), "external CLI handler did not execute")

session.get("/api/v1/app/bootstrap")
frontend = JSON.parse(session.response.body).dig("app", "external_plugin_frontends").find { |entry| entry["name"] == "relocatable_plugin" }
assert!(frontend, "bootstrap omitted the external frontend")
session.get(frontend.fetch("bundle_url"))
assert!(session.response.status == 200, "external frontend bundle was not served")
assert!(session.response.body.include?("registerPluginContribution"), "served bundle does not register a runtime contribution")

puts "plugin relocation acceptance passed"
