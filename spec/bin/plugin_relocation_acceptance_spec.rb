require "rails_helper"
require "open3"

RSpec.describe "external plugin relocation acceptance", :ci_only do
  it "uses the plugin test kit against an external root and boots without it" do
    output, status = Open3.capture2e(Rails.root.join("bin/test-plugin-relocation").to_s, chdir: Rails.root.to_s)

    expect(status).to be_success, output
    expect(output).to include("plugin relocation acceptance passed", "plugin absence boot passed")
  end
end
