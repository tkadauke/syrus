require "rails_helper"
require "tmpdir"

# Plugin deletability is decided by the source boundary scan, not by booting a
# reduced copy of the tree (NY42; formal/SyrusModel/PluginDeletion.lean proves
# that checking the edges leaving kept code is enough). The scan is only as
# good as the coupling kinds it recognizes, so this plants one coupling of
# each known kind from core onto a real plugin and pins the verdict.
#
# The kinds the deletion run used to catch must come back `broken`. A kind
# found later belongs here as a new plant. The two `safe` kinds at the end are
# known gaps: neither this scan nor the old deletion run catches them.
RSpec.describe "plugin deletion plants" do
  PLUGIN = "coworkers".freeze

  def verdict_for(files)
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      files.each do |path, content|
        root.join(path).dirname.mkpath
        root.join(path).write(content)
      end
      File.symlink(Rails.root.join("plugins").to_s, root.join("plugins").to_s)
      audit = Admin::PluginSourceBoundaryAudit.new(root: root)
      Formal::PluginDeletion.call(PLUGIN, audit: audit).verdict
    end
  end

  {
    "a plugin constant" => { "app/models/probe.rb" => "PROBE = Coworkers::Coworker\n" },
    "a plugin constant resolved with constantize" => { "app/models/probe.rb" => "PROBE = \"Coworkers::Coworker\".constantize\n" },
    "a plugin constant resolved with const_get" => { "app/models/probe.rb" => "PROBE = Object.const_get(\"Coworkers::Coworker\")\n" },
    "a require of the plugin library" => { "config/initializers/probe.rb" => "require \"coworkers\"\n" },
    "a route to a plugin controller" => { "config/routes.rb" => "Rails.application.routes.draw { get \"probe\", to: \"coworkers/chats#index\" }\n" },
    "a frontend import of plugin source" => { "app/frontend/probe.tsx" => "import \"../../plugins/coworkers/app/frontend/routes/index\"\n" },
    "a plugin source path" => { "app/models/probe.rb" => "PROBE = Rails.root.join(\"plugins/coworkers/lib/coworkers.rb\")\n" }
  }.each do |kind, files|
    it "calls #{PLUGIN} undeletable for #{kind}" do
      expect(verdict_for(files)).to eq(:broken)
    end
  end

  it "allows an optional lookup with safe_constantize, which survives the plugin's absence" do
    expect(verdict_for("app/models/probe.rb" => "PROBE = \"Coworkers::Coworker\".safe_constantize\n")).to eq(:safe)
  end

  it "allows a printed plugin name" do
    expect(verdict_for("app/models/probe.rb" => "Rails.logger.info(\"Coworkers is optional\")\n")).to eq(:safe)
  end

  it "calls a tree with no coupling deletable" do
    expect(verdict_for("app/models/probe.rb" => "PROBE = 1\n")).to eq(:safe)
  end

  describe "known gaps (neither this scan nor the old deletion run catches them)" do
    it "does not see a bare frontend module-key string" do
      expect(verdict_for("app/frontend/probe.tsx" => "const probe = \"coworkers\"\n")).to eq(:safe)
    end

    it "does not see a schema foreign key into a plugin table" do
      expect(verdict_for("db/schema.rb" => "  add_foreign_key \"jobs\", \"coworker_chats\"\n")).to eq(:safe)
    end
  end
end
