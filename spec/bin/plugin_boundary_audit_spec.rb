require "open3"
require "rails_helper"

RSpec.describe "bin/plugin-boundary-audit" do
  let(:root) { Rails.root.to_s }

  it "removes the selected plugin plus transitive dependents in a temporary copy", :requires_git_checkout do
    command = [
      "test ! -d plugins/ruby",
      "test ! -d plugins/rails",
      "test -d plugins/python",
      "! grep -q 'plugins/ruby' Gemfile",
      "! grep -q 'plugins/rails' Gemfile",
      "grep -q 'plugins/python' Gemfile"
    ].join(" && ")

    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_PATH" => "#{root}/vendor/bundle", "BUNDLE_APP_CONFIG" => "#{root}/.bundle" },
      "bin/plugin-boundary-audit",
      "ruby",
      "--command",
      command,
      chdir: root
    )

    expect(status).to be_success, "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stdout).to include("Removed plugins: ruby, syrus-rails")
    expect(stdout).to include("Result: PASS")
  end

  it "reports unknown plugins before creating a temporary copy" do
    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_PATH" => "#{root}/vendor/bundle", "BUNDLE_APP_CONFIG" => "#{root}/.bundle" },
      "bin/plugin-boundary-audit",
      "missing-plugin",
      "--command",
      "true",
      chdir: root
    )

    expect(status.exitstatus).to eq(64), "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stderr).to include("Unknown bundled plugin: missing-plugin")
  end
end
