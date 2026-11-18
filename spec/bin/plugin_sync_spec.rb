# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"
require "spec_helper"

RSpec.describe "plugin-sync" do
  let(:script) { File.expand_path("../../bin/plugin-sync", __dir__) }

  def archive(files)
    output = StringIO.new("".b)
    Zlib::GzipWriter.wrap(output) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        files.each { |path, body| tar.add_file_simple(path, 0o644, body.bytesize) { |io| io.write(body) } }
      end
    end
    output.string
  end

  def publish(storage, signing_key, revision:, plugins:)
    manifest = JSON.generate(schema_version: 1, revision:, plugins:)
    write_object(storage, "plugins/desired/manifest.json.sig", Base64.strict_encode64(signing_key.sign(manifest)))
    write_object(storage, "plugins/desired/manifest.json", manifest)
  end

  def add_plugin(storage, name:, version:, body: archive("lib/#{name}.rb" => version), **extra)
    digest = Digest::SHA256.hexdigest(body)
    write_object(storage, "plugins/artifacts/#{digest}", body)
    { name:, version:, digest:, size: body.bytesize, roles: [], fleet_quarantined: false }.merge(extra)
  end

  def write_object(storage, key, body)
    path = File.join(storage, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
  end

  def run_sync(storage:, data:, verify_key:, strict: false, env_file: nil)
    env = {
      "SYRUS_PLUGIN_SYNC_STORAGE_PATH" => storage,
      "SYRUS_DATA_ROOT" => data,
      "SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY" => Base64.strict_encode64(verify_key.to_bytes),
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__)
    }
    command = [ "bundle", "exec", "ruby", script ]
    command << "--strict" if strict
    command.push("--env-file", env_file) if env_file
    Open3.capture3(env, *command)
  end

  def active(data, name)
    File.join(data, "plugin-sync/current", name, "lib", "#{name}.rb")
  end

  it "is a no-op when an entrypoint has no desired-state configuration" do
    Dir.mktmpdir do |directory|
      data = File.join(directory, "data")
      env = { "SYRUS_DATA_ROOT" => data, "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }

      _stdout, stderr, status = Open3.capture3(env, "bundle", "exec", "ruby", script, "--if-configured")

      expect(status).to be_success, stderr
      expect(File).not_to exist(File.join(data, "plugin-sync"))
    end
  end

  it "syncs, no-ops, upgrades, downgrades, quarantines, and retains last-good" do
    require "ed25519"
    Dir.mktmpdir do |directory|
      storage = File.join(directory, "storage")
      data = File.join(directory, "data")
      key = Ed25519::SigningKey.generate
      v1 = add_plugin(storage, name: "weather", version: "v1")
      publish(storage, key, revision: 1, plugins: [ v1 ])

      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success
      expect(File.read(active(data, "weather"))).to eq("v1")
      first_target = File.readlink(File.join(data, "plugin-sync/current"))
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success
      expect(File.readlink(File.join(data, "plugin-sync/current"))).to eq(first_target)

      v2 = add_plugin(storage, name: "weather", version: "v2")
      publish(storage, key, revision: 2, plugins: [ v2 ])
      run_sync(storage:, data:, verify_key: key.verify_key)
      expect(File.read(active(data, "weather"))).to eq("v2")
      expect(Pathname.new(data).join("plugin-sync/last-good")).to be_symlink

      publish(storage, key, revision: 3, plugins: [ v1 ])
      run_sync(storage:, data:, verify_key: key.verify_key)
      expect(File.read(active(data, "weather"))).to eq("v1")

      publish(storage, key, revision: 4, plugins: [ v1.merge(fleet_quarantined: true) ])
      run_sync(storage:, data:, verify_key: key.verify_key)
      expect(File).not_to exist(active(data, "weather"))
      expect(JSON.parse(File.read(File.join(data, "plugin-sync/fleet-quarantines.json"))))
        .to eq("weather" => "fleet quarantine in desired plugin state")
    end
  end

  it "keeps the active set on tampering, bad signatures, and unreachable storage, failing only in strict mode" do
    require "ed25519"
    Dir.mktmpdir do |directory|
      storage = File.join(directory, "storage")
      data = File.join(directory, "data")
      key = Ed25519::SigningKey.generate
      plugin = add_plugin(storage, name: "weather", version: "good")
      publish(storage, key, revision: 1, plugins: [ plugin ])
      run_sync(storage:, data:, verify_key: key.verify_key)

      File.binwrite(File.join(storage, "plugins/artifacts", plugin.fetch(:digest)), "tampered")
      publish(storage, key, revision: 2, plugins: [ plugin.merge(version: "bad") ])
      _out, err, status = run_sync(storage:, data:, verify_key: key.verify_key)
      expect(status).to be_success
      expect(err.lines.grep(/plugin-sync:/).length).to eq(1)
      expect(File.read(active(data, "weather"))).to eq("good")

      other_key = Ed25519::SigningKey.generate
      publish(storage, other_key, revision: 3, plugins: [])
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success

      FileUtils.rm_rf(storage)
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success
      expect(run_sync(storage:, data:, verify_key: key.verify_key, strict: true).last).not_to be_success
      expect(File.read(active(data, "weather"))).to eq("good")
    end
  end

  it "keeps fleet quarantine state when a desired artifact fails validation" do
    require "ed25519"
    Dir.mktmpdir do |directory|
      storage = File.join(directory, "storage")
      data = File.join(directory, "data")
      key = Ed25519::SigningKey.generate
      plugin = add_plugin(storage, name: "weather", version: "good", fleet_quarantined: true)
      publish(storage, key, revision: 1, plugins: [ plugin ])
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success

      replacement = add_plugin(storage, name: "weather", version: "bad", fleet_quarantined: false)
      File.binwrite(File.join(storage, "plugins/artifacts", replacement.fetch(:digest)), "tampered")
      publish(storage, key, revision: 2, plugins: [ replacement ])
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success

      expect(JSON.parse(File.read(File.join(data, "plugin-sync/fleet-quarantines.json"))))
        .to eq("weather" => "fleet quarantine in desired plugin state")
    end
  end

  it "writes the active identity to an env file and retains it after a failed sync" do
    require "ed25519"
    Dir.mktmpdir do |directory|
      storage = File.join(directory, "storage")
      data = File.join(directory, "data")
      env_file = File.join(directory, "process.env")
      key = Ed25519::SigningKey.generate
      plugin = add_plugin(storage, name: "weather", version: "good")
      publish(storage, key, revision: 7, plugins: [ plugin ])

      expect(run_sync(storage:, data:, verify_key: key.verify_key, env_file:).last).to be_success
      expected = File.read(File.join(data, "plugin-sync/active.env"))
      expect(File.read(env_file)).to eq(expected)
      expect(expected).to match(/\ASYRUS_PLUGIN_SET_DIGEST=[0-9a-f]{64}\nSYRUS_PLUGIN_SET_REVISION=7\n\z/)

      File.write(env_file, "stale\n")
      FileUtils.rm_rf(storage)
      expect(run_sync(storage:, data:, verify_key: key.verify_key, env_file:).last).to be_success
      expect(File.read(env_file)).to eq(expected)
    end
  end

  it "fails open without last-good, prunes old sets, and ignores interrupted activation links" do
    require "ed25519"
    Dir.mktmpdir do |directory|
      storage = File.join(directory, "missing")
      data = File.join(directory, "data")
      key = Ed25519::SigningKey.generate
      expect(run_sync(storage:, data:, verify_key: key.verify_key).last).to be_success

      FileUtils.mkdir_p(storage)
      4.times do |index|
        plugin = add_plugin(storage, name: "weather", version: "v#{index}")
        publish(storage, key, revision: index + 1, plugins: [ plugin ])
        run_sync(storage:, data:, verify_key: key.verify_key)
      end
      File.symlink("sets/missing", File.join(data, "plugin-sync/current.tmp-interrupted"))
      current = File.read(active(data, "weather"))
      run_sync(storage:, data:, verify_key: key.verify_key)
      expect(File.read(active(data, "weather"))).to eq(current)
      sets = Dir.children(File.join(data, "plugin-sync/sets")).reject { |name| name.start_with?(".") }
      expect(sets.length).to be <= 4
    end
  end
end
