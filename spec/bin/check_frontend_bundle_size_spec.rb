require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe "bin/check-frontend-bundle-size" do
  def run_check(entry_size:, maximum:)
    Dir.mktmpdir("frontend-bundle") do |dir|
      manifest_dir = File.join(dir, ".vite")
      FileUtils.mkdir_p(manifest_dir)
      File.write(File.join(manifest_dir, "manifest.json"), JSON.generate(
        "app/frontend/main.tsx" => { "file" => "spa-entry.js", "isEntry" => true }
      ))
      File.binwrite(File.join(dir, "spa-entry.js"), "x" * entry_size)

      return Open3.capture3(
        { "VITE_BUILD_DIR" => dir, "VITE_ENTRY_MAX_BYTES" => maximum.to_s },
        Rails.root.join("bin/check-frontend-bundle-size").to_s
      )
    end
  end

  it "accepts an entry within the configured budget" do
    stdout, _stderr, status = run_check(entry_size: 99, maximum: 100)

    expect(status).to be_success
    expect(stdout).to include("spa-entry.js")
  end

  it "fails when the entry exceeds the configured budget" do
    _stdout, stderr, status = run_check(entry_size: 101, maximum: 100)

    expect(status).not_to be_success
    expect(stderr).to include("budget is")
  end
end
