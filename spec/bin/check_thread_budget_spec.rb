require "rails_helper"
require "open3"

RSpec.describe "bin/check-thread-budget" do
  let(:script) { Rails.root.join("bin/check-thread-budget").to_s }

  it "renders Rails-style database.yml ERB outside Rails" do
    stdout, stderr, status = Open3.capture3(
      {
        "HOME" => ENV.fetch("HOME"),
        "PATH" => ENV.fetch("PATH"),
        "RAILS_MAX_THREADS" => "10",
        "SYRUS_SQLITE" => nil
      },
      "ruby",
      script
    )

    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).to be_empty
  end
end
