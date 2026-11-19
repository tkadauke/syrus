require "rails_helper"
require "open3"

RSpec.describe "external plugin authoring guide" do
  let(:guide) { Rails.root.join("docs/engineering/conventions/plugins/external.md").read }
  let(:go) { Syrus::SurfaceCatalogs.go_command }

  it "shows only built-in plugin SDK commands advertised by CLI help" do
    shown_commands = guide.scan(/\bsyrus plugin ([a-z][a-z-]*)/).flatten.uniq

    Dir.mktmpdir("plugin-guide-cli") do |temporary|
      binary = Pathname.new(temporary).join("syrus")
      output, status = Open3.capture2e({ "GOWORK" => "off" }, *go, "build", "-o", binary.to_s, ".",
        chdir: Rails.root.join("cli").to_s)
      raise output unless status.success?

      help, help_status = Open3.capture2e(binary.to_s, "plugin", "--help")
      expect(help_status).to be_success
      shown_commands.each { |command| expect(help).to match(/^  #{Regexp.escape(command)}\s/m) }
      expect(shown_commands).to contain_exactly("new", "dev", "validate", "test")
    end
  end

  it "uses valid manifest keys in every Ruby manifest example" do
    manifest_blocks = guide.scan(/syrus_plugin .*? do\n(?<body>.*?)^  end$/m).map(&:first)
    shown_keys = manifest_blocks.flat_map do |body|
      body.scan(/^    ([a-z][a-z0-9_]*)\b/).flatten.map(&:to_sym)
    end.uniq

    expect(manifest_blocks).not_to be_empty
    expect(shown_keys - Syrus::PluginApi::Definition::MANIFEST_KEYS).to be_empty
  end

  it "records the generated example's stable command and runner summaries" do
    expect(guide).to include(<<~TEXT.strip)
      $ syrus plugin new weather_tools --syrus-version 1.2.3
      Created weather_tools
      Run: cd weather_tools && syrus plugin test .
    TEXT
    expect(guide).to include(
      '{"version":1,"mode":"validate","plugin":"weather_tools","validation":"passed","tests":"not_run","exit_code":0}',
      '{"version":1,"mode":"test","plugin":"weather_tools","validation":"passed","tests":"passed","exit_code":0}'
    )
  end
end
