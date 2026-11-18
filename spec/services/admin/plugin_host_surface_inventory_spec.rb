require "rails_helper"
require "tmpdir"

RSpec.describe Admin::PluginHostSurfaceInventory do
  def write(root, relative, contents)
    path = root.join(relative)
    path.dirname.mkpath
    path.write(contents)
  end

  it "uses Ruby syntax to inventory only references to core constants" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      write(root, "app/services/core_thing.rb", "class CoreThing; end\n")
      write(root, "app/services/local.rb", "class Local; end\n")
      write(root, "app/services/shared_name.rb", "class SharedName; end\n")
      write(root, "app/services/core/nested.rb", "module Core; class Nested; end; end\n")
      write(root, "plugins/alpha/lib/alpha.rb", <<~RUBY)
        module Alpha
          class Local; end
          Local.call
          OtherPlugin.call
          Rails.logger.info(JSON.generate({}))
          CoreThing.call
          Core::Nested.call
          ::Core::Nested.call
          ::SharedName.call
        end
      RUBY
      write(root, "plugins/beta/lib/beta.rb", "module OtherPlugin; end\nclass SharedName; end\n")
      surface = instance_double(Syrus::PluginHostSurface, lookup: nil)

      results = described_class.new(root:, surface:).results

      expect(results.map(&:constant)).to eq(%w[Core::Nested CoreThing SharedName])
      expect(results.find { |result| result.constant == "Core::Nested" }).to have_attributes(
        tier: "unlisted", plugins: { "alpha" => 2 }, count: 2
      )
      expect(results.find { |result| result.constant == "CoreThing" }.plugins).to eq({ "alpha" => 1 })
      expect(results.find { |result| result.constant == "SharedName" }.plugins).to eq({ "alpha" => 1 })
    end
  end
end
