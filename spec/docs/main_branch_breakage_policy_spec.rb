require "rails_helper"

RSpec.describe "main branch breakage policy operator docs" do
  it "document the setting, values, inherited-failure gate, and explicit resume path" do
    docs = %w[
      config/syrus_docs/app_settings.md
      config/syrus_docs/landing_queue.md
    ].map { |path| Rails.root.join(path).read }.join("\n")

    expect(docs).to include("main_branch_breakage_policy")
    expect(docs).to include("strict")
    expect(docs).to include("isolate_unrelated_failures")
    expect(docs).to include("Repository#main_health")
    expect(docs).to include("ci_health")
    expect(docs).to include("grader_health")
    expect(docs).to include("repository.landing_paused")
    expect(docs).to include("MainHealthChangedService")
    expect(docs).to include("Repository#land_on_inherited_check_failure")
    expect(docs).to include("repositories#resume_landing")
    expect(docs).to include("LandingQueueProcessorJob")
  end
end
