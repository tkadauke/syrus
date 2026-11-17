require "rails_helper"
require "open3"

RSpec.describe "CLI plugin module boundary" do
  it "keeps plugin modules out of the core CLI module graph and workspace" do
    go_mod = Rails.root.join("cli/go.mod").read
    go_work = Rails.root.join("go.work").read

    expect(go_mod).not_to match(%r{github\.com/tkadauke/syrus/plugins/[^\s]+/cli})
    expect(go_mod).not_to match(%r{replace\s+.*plugins/})
    expect(go_work).not_to match(%r{use\s+\./plugins/[^\s]+/cli})
  end

  it "builds the core CLI with no plugin directories present" do
    skip "mise is required for the isolated CLI build" unless system("command -v mise >/dev/null 2>&1")

    Dir.mktmpdir("syrus-cli-without-plugins") do |directory|
      FileUtils.cp_r(Rails.root.join("cli"), directory)
      cli_directory = File.join(directory, "cli")
      output, status = Open3.capture2e(
        { "GOWORK" => "off" },
        "mise", "exec", "go@1.26.5", "--", "go", "build", "./...",
        chdir: cli_directory
      )

      expect(status).to be_success, output
    end
  end
end
