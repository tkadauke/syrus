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
      write(root, "lib/syrus/host/undeclared.rb", "module Syrus::Host::Undeclared; end\n")
      write(root, "plugins/alpha/lib/alpha.rb", <<~RUBY)
        module Alpha
          class Local; end
          module Nested
            Local.call
          end
          OtherPlugin.call
          Rails.logger.info(JSON.generate({}))
          CoreThing.call
          Syrus::Host::Undeclared.call
          Core::Nested.call
          ::Core::Nested.call
          ::SharedName.call
        end
        module Alpha::Nested
          Local.call
        end
      RUBY
      write(root, "plugins/beta/lib/beta.rb", "module OtherPlugin; end\nclass SharedName; end\n")
      surface = instance_double(Syrus::PluginHostSurface)
      allow(surface).to receive(:public?).and_return(false)
      allow(surface).to receive(:allowed_internal?) { |name| name == "CoreThing" }

      results = described_class.new(root:, surface:).results

      expect(results.map(&:constant)).to eq(%w[Core::Nested CoreThing Local SharedName Syrus::Host::Undeclared])
      expect(results.find { |result| result.constant == "Core::Nested" }).to have_attributes(
        tier: "internal", plugins: { "alpha" => 2 }, count: 2
      )
      expect(results.find { |result| result.constant == "CoreThing" }.plugins).to eq({ "alpha" => 1 })
      expect(results.find { |result| result.constant == "CoreThing" }.tier).to eq("allowlisted")
      expect(results.find { |result| result.constant == "Syrus::Host::Undeclared" }.tier).to eq("internal")
      expect(results.find { |result| result.constant == "Local" }.plugins).to eq({ "alpha" => 1 })
      expect(results.find { |result| result.constant == "SharedName" }.plugins).to eq({ "alpha" => 1 })
    end
  end

  it "parses each source file once while building an inventory" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      write(root, "app/services/core_thing.rb", "class CoreThing; end\n")
      write(root, "plugins/alpha/app/services/alpha/use_core.rb", "CoreThing.call\n")
      parsed_paths = []
      allow(Prism).to receive(:parse_file).and_wrap_original do |method, path|
        parsed_paths << Pathname.new(path).expand_path
        method.call(path)
      end
      surface = instance_double(Syrus::PluginHostSurface, public?: false, allowed_internal?: false)

      described_class.new(root:, surface:).results

      expect(parsed_paths.tally.values).to all(eq(1))
      expect(parsed_paths).to contain_exactly(
        root.join("app/services/core_thing.rb").expand_path,
        root.join("plugins/alpha/app/services/alpha/use_core.rb").expand_path
      )
    end
  end
end
