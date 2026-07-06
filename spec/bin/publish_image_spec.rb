# frozen_string_literal: true

require "open3"
require "spec_helper"

RSpec.describe "bin/publish-image" do
  let(:script_path) { File.expand_path("../../bin/publish-image", __dir__) }
  let(:script) { File.read(script_path, encoding: "UTF-8") }

  it "passes a bash syntax check" do
    _out, err, status = Open3.capture3("bash", "-n", script_path)
    expect(status.exitstatus).to eq(0), err
  end

  it "supports publishing test images from a fork" do
    # SYRUS_IMAGE_REPO + GHCR_USER let a fork publish e.g.
    # ghcr.io/<user>/syrus-backend without editing the script; upstream stays
    # the default so the release runbook is unchanged.
    expect(script).to include('IMAGE="${SYRUS_IMAGE_REPO:-ghcr.io/tkadauke/syrus-backend}"')
    expect(script).to include('GHCR_USER="${GHCR_USER:-tkadauke}"')
  end
end
