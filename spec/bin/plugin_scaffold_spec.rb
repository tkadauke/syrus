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

  def generate(binary, directory, *flags, version: "0.1.0")
    output, status = Open3.capture2e(binary.to_s, "plugin", "new", "sample_plugin", "--path", directory.to_s,
      "--syrus-version", version, *flags)
    raise output unless status.success?
    output
  end

  def files(root)
    Find.find(root).select { |path| File.file?(path) }
      .to_h { |path| [ Pathname.new(path).relative_path_from(root).to_s, File.binread(path) ] }
  end

  it "generates variants that validate and test successfully" do
    Dir.mktmpdir("plugin-scaffold-acceptance") do |temporary|
      binary = build_cli(temporary)
      [ [], [ "--frontend" ], [ "--model" ], [ "--cli" ], [ "--frontend", "--model", "--cli" ] ].each_with_index do |flags, index|
        plugin = Pathname.new(temporary).join("variant-#{index}/sample_plugin")
        generation_output = generate(binary, plugin, *flags)
        expect(generation_output).to eq("Created #{plugin}\nRun: cd #{plugin} && syrus plugin test .\n")
        output, status = Open3.capture2e(
          { "SYRUS_PLUGIN_TEST_MODE" => "test", "SYRUS_PLUGIN_TEST_JSON" => "1", "SYRUS_VERSION" => "0.1.0" },
          Rails.root.join("bin/plugin-test").to_s, plugin.to_s, chdir: Rails.root.to_s
        )
        expect(status).to be_success, output
        json_line = output.lines.reverse_each.find { |line| line.strip.present? }
        expect(JSON.parse(json_line)).to include("validation" => "passed", "tests" => "passed")
      end
    end
  end

  it "keeps the Rails generator byte-identical to the CLI" do
    Dir.mktmpdir("plugin-scaffold-parity") do |temporary|
      root = Pathname.new(temporary)
      cli_plugin = root.join("cli/sample_plugin")
      rails_root = root.join("rails")
      generate(build_cli(temporary), cli_plugin, "--frontend", "--model", "--cli", version: "v1.2.3")
      described_class = Syrus::Plugin::PluginGenerator
      described_class.start([ "sample_plugin", "--frontend", "--model", "--cli", "--syrus-version", "v1.2.3" ], destination_root: rails_root)

      expect(files(rails_root.join("plugins/sample_plugin"))).to eq(files(cli_plugin))
      expect(cli_plugin.join("sample_plugin.gemspec").read).to include('requires_syrus"] = ">= 1.2.3"')
    end
  end
end
