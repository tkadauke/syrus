# frozen_string_literal: true

require "json"
require "open3"
require "spec_helper"
require "tmpdir"

RSpec.describe "website release metadata sync" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:script_path) { File.join(repo_root, "website/scripts/sync-release.mjs") }
  let(:syrus_yml) { File.read(File.join(repo_root, ".syrus.yml")) }

  it "lets the website-build grader validate committed release metadata without rewriting drift" do
    Dir.mktmpdir("syrus-release-sync") do |dir|
      release_path = File.join(dir, "release.json")
      committed = {
        version: "0.1.0",
        mac: { size: 111 },
        windows: { size: 222 },
      }
      File.write(release_path, JSON.pretty_generate(committed) + "\n")

      stdout, stderr, status = Open3.capture3(
        { "SYRUS_RELEASE_JSON_PATH" => release_path },
        "node",
        script_path,
        "--check-only",
      )

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include("checked committed release.json")
      expect(JSON.parse(File.read(release_path), symbolize_names: true)).to eq(committed)
    end
  end

  it "runs website-build with the non-mutating release metadata check" do
    expect(syrus_yml).to include("npm --prefix website run sync-release:check && npm --prefix website run build")
    expect(syrus_yml).not_to include("npm --prefix website run sync-release && npm --prefix website run build")
  end
end
