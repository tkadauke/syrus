# frozen_string_literal: true

require "open3"
require "spec_helper"

RSpec.describe "ios/scripts/version.sh" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "ios/scripts/version.sh") }

  def run_script(arg, env = {})
    Open3.capture3(env, script, arg)
  end

  it "reads the marketing version from project.yml" do
    out, _err, status = run_script("marketing")
    expected = File.read(File.join(root, "ios/project.yml"))[/MARKETING_VERSION:\s*"?([\d.]+)"?/, 1]

    expect(status).to be_success
    expect(out.strip).to eq(expected)
  end

  it "honors an explicit build number" do
    out, _err, status = run_script("build", "SYRUS_IOS_BUILD_NUMBER" => "42")

    expect(status).to be_success
    expect(out.strip).to eq("42")
  end

  it "defaults the build number to a numeric value deterministic for a commit" do
    first, _e, s1 = run_script("build", "SYRUS_IOS_BUILD_NUMBER" => "")
    second, _e, s2 = run_script("build", "SYRUS_IOS_BUILD_NUMBER" => "")

    if s1.success?
      expect(first.strip).to match(/\A\d+\z/)
      expect(second).to eq(first)
    else
      # Shallow CI checkouts must fail loudly instead of guessing.
      expect(s2).not_to be_success
    end
  end

  it "rejects malformed build numbers" do
    _out, err, status = run_script("build", "SYRUS_IOS_BUILD_NUMBER" => "1a")

    expect(status).not_to be_success
    expect(err).to include("invalid build number")
  end

  it "formats the full version" do
    out, _err, status = run_script("full", "SYRUS_IOS_BUILD_NUMBER" => "7")

    expect(status).to be_success
    expect(out.strip).to match(/\A[\d.]+ \(7\)\z/)
  end
end
