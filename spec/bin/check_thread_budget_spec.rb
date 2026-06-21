# frozen_string_literal: true

require "open3"
require "spec_helper"

RSpec.describe "bin/check-thread-budget" do
  it "renders Rails config ERB outside Rails and validates the worker pool budget" do
    root = File.expand_path("../..", __dir__)

    stdout, stderr, status = Open3.capture3({ "SYRUS_SQLITE" => nil }, "ruby", "bin/check-thread-budget", chdir: root)

    expect(status).to be_success, "expected success, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).to be_empty
  end
end
