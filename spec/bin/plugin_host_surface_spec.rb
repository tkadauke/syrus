require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe "bin/plugin-host-surface" do
  it "prints JSON and exits non-zero for unsupported host references" do
    Dir.mktmpdir do |directory|
      plugin = Pathname.new(directory)
      plugin.join("lib").mkpath
      plugin.join("lib/external.rb").write("MainHealthChangedService.call\n")

      stdout, stderr, status = Open3.capture3(
        Rails.root.join("bin/plugin-host-surface").to_s, "scan", plugin.to_s, "--json",
        chdir: Rails.root.to_s
      )

      expect(stderr).to be_empty
      expect(status.exitstatus).to eq(1)
      payload = JSON.parse(stdout)
      expect(payload).not_to have_key("legacy")
      expect(payload.fetch("unlisted").first).to include(
        "constant" => "MainHealthChangedService", "path" => "lib/external.rb", "line" => 1
      )
    end
  end

  it "prints dynamic host references as structured JSON" do
    Dir.mktmpdir do |directory|
      plugin = Pathname.new(directory)
      plugin.join("lib").mkpath
      plugin.join("lib/external.rb").write("\"MainHealthChangedService\".constantize\n")

      stdout, stderr, status = Open3.capture3(
        Rails.root.join("bin/plugin-host-surface").to_s, "scan", plugin.to_s, "--json",
        chdir: Rails.root.to_s
      )

      expect(stderr).to be_empty
      expect(status).to be_success
      expect(JSON.parse(stdout).fetch("dynamic").first).to include(
        "constant" => "MainHealthChangedService", "tier" => "dynamic",
        "path" => "lib/external.rb", "line" => 1, "method" => "constantize"
      )
    end
  end
end
