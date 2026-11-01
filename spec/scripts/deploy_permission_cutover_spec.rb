require "rails_helper"

RSpec.describe "coworker permission cutover deployment guard" do
  let(:deploy) { Rails.root.join("bin/deploy").read }

  it "fails closed before build for a production cutover without adding a runtime mode" do
    guard_at = deploy.index("bin/check-coworker-permission-cutover-deployment")
    build_at = deploy.index("# --- build + push")

    expect(guard_at).to be < build_at
    expect(deploy).to include("SYRUS_COWORKER_CUTOVER_TARGET_SHA", "SYRUS_COWORKER_CUTOVER_PREVIOUS_SHA")
    expect(deploy).not_to match(/permission[_-](mode|bypass|fallback)/i)
  end
end
