require "rails_helper"
require "open3"

RSpec.describe "bin/plugin-recovery" do
  it "lists, quarantines, and clears a plugin without loading its broken entry file" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      plugin_root = root.join("plugins")
      broken = plugin_root.join("broken")
      broken.join("lib").mkpath
      broken.join("lib/broken.rb").write("raise 'must not load'")
      env = { "SYRUS_DATA_ROOT" => root.to_s, "SYRUS_PLUGIN_PATH" => plugin_root.to_s, "SYRUS_PLUGIN_SYNC_ENABLED" => "0" }

      output, status = Open3.capture2e(env, Rails.root.join("bin/plugin-recovery").to_s, "quarantine", "broken")
      expect(status).to be_success
      expect(output).to include("Quarantined broken")

      output, status = Open3.capture2e(env, Rails.root.join("bin/plugin-recovery").to_s, "list")
      expect(status).to be_success
      expect(output).to include("broken\tmanually quarantined")

      _output, status = Open3.capture2e(env, Rails.root.join("bin/plugin-recovery").to_s, "clear", "broken")
      expect(status).to be_success
    end
  end
end
