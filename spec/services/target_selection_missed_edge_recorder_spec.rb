require "rails_helper"

RSpec.describe TargetSelectionMissedEdgeRecorder do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, repository: repository, kind: "main_grader", issue_title: "main_grader:abc123", issue_number: nil) }
  let(:workflow) { Workflows::MainGrader.instantiate(job: job, artifacts: { "main_sha" => "abc123", "previous_main_sha" => "old123" }) }

  it "records a warning when CI fails a check matching a previously skipped grader" do
    fanout = workflow.steps.find_by!(kind: "grader_fanout")
    workflow.set_artifact!(
      Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY,
      [
        {
          "name" => "docs-tests",
          "required" => true,
          "target_label" => "//:grade/docs-tests",
          "affected" => false,
          "reason" => "no matching files changed"
        }
      ]
    )

    expect {
      described_class.record_ci_failures!(
        repository: repository,
        sha: "abc123",
        failed_checks: [ { "name" => "docs-tests", "url" => "https://example.test/check" } ]
      )
    }.to change(WorkflowWarning.where(kind: described_class::KIND), :count).by(1)

    warning = WorkflowWarning.last
    expect(warning.workflow).to eq(workflow)
    expect(warning.step).to eq(fanout)
    expect(warning.severity).to eq("high")
    expect(warning.evidence).to include(
      "grader_name" => "docs-tests",
      "target_label" => "//:grade/docs-tests",
      "detected_by" => "ci"
    )
    expect(warning.suggested_prompt).to include("Add the missing dependency edge")
  end
end
