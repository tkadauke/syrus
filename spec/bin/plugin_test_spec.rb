# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "bin/plugin-test", :requires_git_checkout do
  def run_plugin(mode, mutate: nil, json: false)
    Dir.mktmpdir("plugin-test-runner") do |directory|
      root = Pathname(directory).join("relocatable_plugin")
      FileUtils.cp_r(Rails.root.join("spec/fixtures/relocatable_plugin"), root)
      system(Rails.root.join("bin/build-plugin-frontend").to_s, root.to_s, exception: true)
      File.write(root.join("spec/relocatable_plugin_spec.rb"), <<~RUBY)
        require File.join(ENV.fetch("SYRUS_HOST_ROOT"), "spec/spec_helper")
        require File.join(ENV.fetch("SYRUS_HOST_ROOT"), "config/environment")
        require "rspec/rails"
        require "syrus/plugin/test_kit"
        RSpec.describe "plugin specs" do
          it("passes") { expect(#{mutate == :failing_spec ? "false" : "true"}).to be(true) }
        end
      RUBY
      if mutate == :invalid
        gemspec = root.join("relocatable_plugin.gemspec")
        File.write(gemspec, File.read(gemspec).sub("end\n", "  spec.add_dependency \"not_shipped_by_syrus\"\nend\n"))
      end
      environment = json ? { "SYRUS_PLUGIN_TEST_JSON" => "1" } : {}
      Open3.capture3(environment, Rails.root.join("bin/plugin-test").to_s, mode, root.to_s, chdir: Rails.root.to_s)
    end
  end

  it "reports a passing plugin and its specs" do
    stdout, stderr, status = run_plugin("test")
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout.lines.last)).to include("validation" => "passed", "tests" => "passed", "status" => "passed")
  end

  it "reports validation failures" do
    stdout, _stderr, status = run_plugin("validate", mutate: :invalid)
    expect(status).not_to be_success
    expect(JSON.parse(stdout.lines.last)).to include("validation" => "failed", "tests" => "skipped", "status" => "failed")
  end

  it "reports plugin spec failures" do
    stdout, stderr, status = run_plugin("test", mutate: :failing_spec)
    expect(status).not_to be_success
    expect(JSON.parse(stdout.lines.last)).to include("validation" => "passed", "tests" => "failed", "status" => "failed"), stderr
  end

  it "prints only the summary in JSON mode" do
    stdout, stderr, status = run_plugin("test", json: true)
    expect(status).to be_success, stderr
    expect(stdout.lines.size).to eq(1)
    expect(JSON.parse(stdout)).to include("schema" => "syrus.plugin-test.v1", "status" => "passed")
    expect(stderr).to be_empty
  end
end
