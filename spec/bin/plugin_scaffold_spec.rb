require "rails_helper"
require "open3"
require "find"
require "generators/syrus/plugin/plugin_generator"

RSpec.describe "plugin scaffold acceptance", :aggregate_failures do
  let(:go) { Syrus::SurfaceCatalogs.go_command }

  def build_cli(directory)
    binary = Pathname.new(directory).join("syrus")
    output, status = Open3.capture2e({ "GOWORK" => "off" }, *go, "build", "-o", binary.to_s, ".", chdir: Rails.root.join("cli").to_s)
    raise output unless status.success?
    binary
  end

  def generate(binary, directory, *flags)
    output, status = Open3.capture2e(binary.to_s, "plugin", "new", "sample_plugin", "--path", directory.to_s,
      "--syrus-version", "0.1.0", *flags)
    raise output unless status.success?
  end

  def files(root)
    Find.find(root).select { |path| File.file?(path) }
      .to_h { |path| [ Pathname.new(path).relative_path_from(root).to_s, File.binread(path) ] }
  end

  it "generates variants that validate and test successfully" do
    Dir.mktmpdir("plugin-scaffold-acceptance") do |temporary|
      binary = build_cli(temporary)
      [ [], [ "--frontend" ], [ "--model" ], [ "--cli" ], [ "--frontend", "--model", "--cli" ] ].each_with_index do |flags, index|
        plugin = Pathname.new(temporary).join("variant-#{index}")
        generate(binary, plugin, *flags)
        output, status = Open3.capture2e(
          { "SYRUS_PLUGIN_TEST_MODE" => "test", "SYRUS_PLUGIN_TEST_JSON" => "1", "SYRUS_VERSION" => "0.1.0" },
          Rails.root.join("bin/plugin-test").to_s, plugin.to_s, chdir: Rails.root.to_s
        )
        expect(status).to be_success, output
        expect(JSON.parse(output.lines.last)).to include("validation" => "passed", "tests" => "passed")
      end
    end
  end

  it "keeps the Rails generator byte-identical to the CLI" do
    Dir.mktmpdir("plugin-scaffold-parity") do |temporary|
      root = Pathname.new(temporary)
      cli_plugin = root.join("cli/sample_plugin")
      rails_root = root.join("rails")
      generate(build_cli(temporary), cli_plugin, "--frontend", "--model", "--cli")
      described_class = Syrus::Plugin::PluginGenerator
      described_class.start([ "sample_plugin", "--frontend", "--model", "--cli", "--syrus-version", "0.1.0" ], destination_root: rails_root)

      expect(files(rails_root.join("plugins/sample_plugin"))).to eq(files(cli_plugin))
    end
  end
end
