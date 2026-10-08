require "rails_helper"

RSpec.describe Prompts::VisualDiff do
  it "shows after-artifact provenance and explains invalid captures are prefiltered" do
    job = Factories.job_record(branch_name: "syrus/direct-123")
    prompt = described_class.new(
      job: job,
      after_artifacts: [
        {
          "title" => "Credential Store after change",
          "image_url" => "/after.png",
          "page" => {
            "path" => "/credential_store",
            "title" => "Credential Store"
          }
        }
      ],
      baseline_type: VisualDiffSubmission::BASELINE_TYPE,
      base_branch: "main"
    ).to_s

    expect(prompt).to include("filtered out obvious auth/sign-in/error-wall captures")
    expect(prompt).to include("Credential Store after change: /after.png")
    expect(prompt).to include('captured path "/credential_store"')
    expect(prompt).to include('captured title "Credential Store"')
  end
end
