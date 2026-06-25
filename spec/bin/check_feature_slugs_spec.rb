# frozen_string_literal: true

require "fileutils"
require "open3"
require "spec_helper"
require "tmpdir"

RSpec.describe "bin/check_feature_slugs" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check_feature_slugs") }

  around do |example|
    Dir.mktmpdir("feature-slugs") do |dir|
      @dir = dir
      example.run
    end
  end

  def write(path, contents)
    full_path = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def run_check
    Open3.capture3(script, chdir: @dir)
  end

  it "passes when all referenced feature slugs are declared" do
    write("config/features.yml", <<~YAML)
      features:
        - slug: ruby_flag
        - slug: quoted_flag
        - slug: frontendFlag
        - slug: bracket-flag
    YAML
    write("app/models/example.rb", <<~RUBY)
      Feature.enabled?(:ruby_flag)
      Feature.enabled?("quoted_flag")
    RUBY
    write("app/frontend/example.tsx", <<~TSX)
      featureFlags.frontendFlag
      featureFlags["bracket-flag"]
    TSX

    stdout, stderr, status = run_check

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-feature-slugs] ok (4 referenced, 4 declared)")
    expect(stderr).to be_empty
  end

  it "fails and lists locations for undeclared referenced slugs" do
    write("config/features.yml", "features: []\n")
    write("app/models/example.rb", "Feature.enabled?(:missing_feature)\n")
    write("app/frontend/example.tsx", "featureFlags[\"missing-frontend\"]\n")

    stdout, stderr, status = run_check

    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    expect(stderr).to include("[check-feature-slugs] undeclared feature slug references found:")
    expect(stderr).to include("missing_feature: app/models/example.rb:1")
    expect(stderr).to include("missing-frontend: app/frontend/example.tsx:1")
  end

  it "warns but passes when declared slugs have no code references" do
    write("config/features.yml", <<~YAML)
      features:
        - slug: active_flag
        - slug: unused_flag
    YAML
    write("app/models/example.rb", "Feature.enabled?(:active_flag)\n")

    stdout, stderr, status = run_check

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-feature-slugs] ok (1 referenced, 2 declared)")
    expect(stderr).to include("[check-feature-slugs] warning: declared feature slugs have no code references:")
    expect(stderr).to include("unused_flag")
  end
end
