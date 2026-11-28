require "rails_helper"
require "open3"
require "securerandom"
require "tmpdir"

RSpec.describe "bin/check-frontend-bundle-size" do
  def run_check(manifest:, files:, env: {})
    Dir.mktmpdir("frontend-bundle") do |dir|
      manifest_dir = File.join(dir, ".vite")
      FileUtils.mkdir_p(manifest_dir)
      File.write(File.join(manifest_dir, "manifest.json"), JSON.generate(manifest))
      files.each { |name, content| File.binwrite(File.join(dir, name), content) }

      return Open3.capture3(
        { "VITE_BUILD_DIR" => dir }.merge(env),
        Rails.root.join("bin/check-frontend-bundle-size").to_s
      )
    end
  end

  def entry_manifest(imports: [])
    { "app/frontend/main.tsx" => { "file" => "spa-entry.js", "isEntry" => true, "imports" => imports } }
  end

  it "accepts an entry within the configured budget" do
    stdout, _stderr, status = run_check(manifest: entry_manifest, files: { "spa-entry.js" => "x" * 99 }, env: { "VITE_ENTRY_MAX_BYTES" => "100" })

    expect(status).to be_success
    expect(stdout).to include("spa-entry.js")
  end

  it "fails when the entry exceeds the configured budget" do
    _stdout, stderr, status = run_check(manifest: entry_manifest, files: { "spa-entry.js" => "x" * 101 }, env: { "VITE_ENTRY_MAX_BYTES" => "100" })

    expect(status).not_to be_success
    expect(stderr).to include("budget is")
  end

  it "budgets the gzipped entry plus every chunk it statically imports, not dynamic imports" do
    # Random bytes do not compress, so gzip size tracks the raw size.
    manifest = entry_manifest(imports: [ "_shared.js" ]).merge(
      "_shared.js" => { "file" => "spa-shared.js" },
      "app/frontend/routes/Chat.tsx" => { "file" => "spa-Chat.js", "isDynamicEntry" => true }
    )
    files = {
      "spa-entry.js" => SecureRandom.random_bytes(2_000),
      "spa-shared.js" => SecureRandom.random_bytes(2_000),
      "spa-Chat.js" => SecureRandom.random_bytes(50_000)
    }

    stdout, stderr, status = run_check(manifest: manifest, files: files, env: { "VITE_STARTUP_MAX_GZIP_BYTES" => "6000" })
    expect(status).to be_success, stderr
    expect(stdout).to include("across 2 chunks")

    _stdout, stderr, status = run_check(manifest: manifest, files: files, env: { "VITE_STARTUP_MAX_GZIP_BYTES" => "3000" })
    expect(status).not_to be_success
    expect(stderr).to include("Startup JavaScript is")
    expect(stderr).to include("spa-shared.js")
  end

  it "fails when a lazily loaded module becomes statically reachable from startup" do
    manifest = entry_manifest(imports: [ "app/frontend/routes/Chat.tsx" ]).merge(
      "app/frontend/routes/Chat.tsx" => { "file" => "spa-Chat.js", "isDynamicEntry" => true }
    )

    _stdout, stderr, status = run_check(manifest: manifest, files: { "spa-entry.js" => "x", "spa-Chat.js" => "y" })

    expect(status).not_to be_success
    expect(stderr).to include("statically reachable from the startup entry")
    expect(stderr).to include("app/frontend/routes/Chat.tsx")
  end
end
