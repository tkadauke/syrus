require "rails_helper"

RSpec.describe Steps::VisualDiff do
  def visual_diff_run_for(job, artifacts:)
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "visual_diff",
      artifacts: {
        "visual_diff_after_artifacts" => artifacts,
        "visual_diff_baseline_type" => VisualDiffSubmission::BASELINE_TYPE
      }
    )
    step = Step.create!(workflow: workflow, kind: "visual_diff", position: 1)
    step.runs.create!(job: job, trigger_kind: "visual_diff")
  end

  def credential_store_sign_in_artifact
    {
      "type" => "visual_review_screenshot_run_10_1",
      "title" => "Credential Store after change",
      "image_url" => "/api/v1/app/workflows/10/visual_artifact?type=visual_review_screenshot_run_10_1",
      "content_type" => "image/png",
      "byte_size" => 123,
      "page" => {
        "path" => "/session/new",
        "title" => "Sign in"
      }
    }
  end

  it "pairs baseline screenshots by title and falls back to capture order" do
    workflow = Workflow.create!(job: Factories.job_record, trigger_kind: "visual_diff")
    after_artifacts = [
      {
        "title" => "Dashboard",
        "image_url" => "/after-dashboard.png",
        "type" => "after-1",
        "source" => "current_browser",
        "captured_at" => "2026-10-09T12:00:00.000Z",
        "page" => {
          "path" => "/dashboard",
          "title" => "Dashboard"
        },
        "viewport" => {
          "width" => 1440,
          "height" => 900,
          "device_scale_factor" => 1
        }
      },
      { "title" => "Settings", "image_url" => "/after-settings.png", "type" => "after-2" }
    ]
    baselines = [
      { "type" => "before-settings", "title" => "Settings", "payload" => { "image_url" => "/before-settings.png" } },
      {
        "type" => "before-dashboard",
        "title" => "Dashboard",
        "payload" => {
          "image_url" => "/before-dashboard.png",
          "source" => "current_browser",
          "captured_at" => "2026-10-09T12:05:00.000Z",
          "page" => {
            "path" => "/dashboard",
            "title" => "Dashboard"
          },
          "viewport" => {
            "width" => 1440,
            "height" => 900,
            "device_scale_factor" => 1
          }
        }
      }
    ]

    pairs = described_class::VisualDiffPairs.new(
      workflow: workflow,
      after_artifacts: after_artifacts,
      baseline_entries: baselines
    ).pairs

    expect(pairs.map { |pair| [ pair["title"], pair.dig("before", "image_url"), pair.dig("after", "image_url") ] }).to eq([
      [ "Dashboard", "/before-dashboard.png", "/after-dashboard.png" ],
      [ "Settings", "/before-settings.png", "/after-settings.png" ]
    ])
    expect(pairs.first.fetch("after")).to include(
      "source" => "current_browser",
      "captured_at" => "2026-10-09T12:00:00.000Z",
      "page" => {
        "path" => "/dashboard",
        "title" => "Dashboard"
      },
      "viewport" => {
        "width" => 1440,
        "height" => 900,
        "device_scale_factor" => 1
      }
    )
    expect(pairs.first.fetch("before")).to include(
      "source" => "current_browser",
      "captured_at" => "2026-10-09T12:05:00.000Z",
      "page" => {
        "path" => "/dashboard",
        "title" => "Dashboard"
      },
      "viewport" => {
        "width" => 1440,
        "height" => 900,
        "device_scale_factor" => 1
      }
    )
  end

  it "returns no pairs when baseline screenshots are missing" do
    workflow = Workflow.create!(job: Factories.job_record, trigger_kind: "visual_diff")

    pairs = described_class::VisualDiffPairs.new(
      workflow: workflow,
      after_artifacts: [ { "title" => "Dashboard", "image_url" => "/after.png" } ],
      baseline_entries: []
    ).pairs

    expect(pairs).to be_empty
  end

  it "rejects invalid after artifacts before prompting for baselines" do
    job = Factories.job_record(
      issue_title: "Review the Credential Store route",
      issue_body: "The changed surface is Credential Store."
    )
    run = visual_diff_run_for(job, artifacts: [ credential_store_sign_in_artifact ])
    handler = described_class.new(run)

    accepted = handler.send(:validated_after_artifacts)

    expect(accepted).to be_empty
    expect(run.workflow.reload.artifact("visual_diff_after_artifacts")).to be_empty
    expect(run.workflow.artifact("visual_diff_rejected_after_artifacts")).to contain_exactly(include(
      "title" => "Credential Store after change",
      "rejected_reason" => include("auth/error screen", "Credential Store after change")
    ))
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("invalid after artifact")
  end

  it "does not pair a rejected after artifact with a matching sign-in baseline" do
    job = Factories.job_record(
      issue_title: "Review the Credential Store route",
      issue_body: "The changed surface is Credential Store."
    )
    run = visual_diff_run_for(job, artifacts: [ credential_store_sign_in_artifact ])
    handler = described_class.new(run)
    after_artifacts = handler.send(:validated_after_artifacts)
    baselines = [
      {
        "type" => "visual_diff_baseline_screenshot_run_99_1",
        "title" => "Credential Store after change",
        "payload" => {
          "image_url" => "/before-sign-in.png",
          "page" => {
            "path" => "/session/new",
            "title" => "Sign in"
          }
        }
      }
    ]

    pairs = described_class::VisualDiffPairs.new(
      workflow: run.workflow,
      after_artifacts: after_artifacts,
      baseline_entries: baselines
    ).pairs

    expect(pairs).to be_empty
  end
end
