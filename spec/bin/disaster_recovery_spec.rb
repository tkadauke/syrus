require "rails_helper"
require "open3"

RSpec.describe "bin/disaster-recovery" do
  it "starts and reports usage without booting Rails" do
    output, status = Open3.capture2e({ "DATABASE_URL" => "invalid://must-not-connect" }, Rails.root.join("bin/disaster-recovery").to_s)
    expect(status.exitstatus).to eq(64)
    expect(output).to include("bin/disaster-recovery COMMAND")
  end
end
