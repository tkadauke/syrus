require "open3"
require "spec_helper"

RSpec.describe "bin/check-thread-budget" do
  it "renders Rails-style YAML ERB without booting Rails" do
    stdout, stderr, status = Open3.capture3("bin/check-thread-budget", chdir: File.expand_path("../..", __dir__))

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-thread-budget] ok")
  end
end
