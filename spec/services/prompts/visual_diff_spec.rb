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
          },
          "payload" => { "subject" => "[data-testid=credential-list]" }
        }
      ],
      baseline_type: VisualDiffSubmission::BASELINE_TYPE,
      base_branch: "main"
    ).to_s

    expect(prompt).to include("filtered out obvious auth/sign-in/error-wall captures")
    expect(prompt).to include("Credential Store after change: /after.png")
    expect(prompt).to include('captured path "/credential_store"')
    expect(prompt).to include('captured title "Credential Store"')
    expect(prompt).to include('subject: "[data-testid=credential-list]"')
    expect(prompt).to include("exact same title as the paired after screenshot")
    expect(prompt).to include("reuse the exact value when it is a stable CSS selector")
  end

  it "requires ref-based subjects to be resolved for the baseline page instead of reused" do
    job = Factories.job_record(branch_name: "syrus/direct-123")
    prompt = described_class.new(
      job: job,
      after_artifacts: [
        {
          "title" => "Results after change",
          "image_url" => "/results-after.png",
          "payload" => { "subject" => "e12" }
        }
      ],
      baseline_type: VisualDiffSubmission::BASELINE_TYPE,
      base_branch: "main"
    ).to_s

    expect(prompt).to include('subject: "e12"')
    expect(prompt).to include("call `browser_snapshot` in the baseline page")
    expect(prompt).to include("pass the newly resolved ref for that element")
    expect(prompt).to include("never reuse a stale ref from the after capture or an earlier baseline page state")
  end
end
