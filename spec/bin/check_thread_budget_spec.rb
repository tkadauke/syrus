require "rails_helper"
require "open3"

RSpec.describe "bin/check-thread-budget" do
  let(:script) { Rails.root.join("bin/check-thread-budget").to_s }

  it "renders Rails config ERB that uses ActiveSupport present predicates" do
    stdout, stderr, status = Open3.capture3(
      { "RAILS_MAX_THREADS" => "10", "SYRUS_SQLITE" => nil },
      "ruby",
      script
    )

    expect(status).to be_success, "expected success, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stderr).not_to include("undefined method `present?'")
    expect(stdout).to include("[check-thread-budget] ok")
  end
end
