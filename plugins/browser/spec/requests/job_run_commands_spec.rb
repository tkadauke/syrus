require "rails_helper"

RSpec.describe "Browser job run commands", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job(repository:) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def app_job_path(path) = "/api/v1/app/jobs/#{job.id}#{path}"

  def finish_initial_workflow!
    run = job.initial_run
    run.step.workflow.update_columns(state: "succeeded", finished_at: Time.current)
    run.step.update_columns(state: "succeeded", finished_at: Time.current)
    run.update_columns(state: "succeeded", finished_at: Time.current)
    WorkUnit.joins(:work_unit_members).where(work_unit_members: { job_id: job.id })
      .find_each { |unit| unit.mark_terminal!("succeeded") }
  end

  def configure_visual_review(enabled:)
    enabled ? stub_workflow_judge(step_kind: "visual_review") : stub_no_workflow_judges
  end

  it "queues a manual visual review workflow for an implemented job" do
    configure_visual_review(enabled: true)
    finish_initial_workflow!
    job.update_columns(state: "implemented")

    expect { post app_job_path("/visual_review"), as: :json }
      .to change { job.reload.workflows.where(trigger_kind: "manual_visual_review").count }.by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Visual review enqueued.")
  end

  it "rejects a manual visual review request when the job is not runnable" do
    configure_visual_review(enabled: true)
    job.update_columns(state: "running")

    expect { post app_job_path("/visual_review"), as: :json }.not_to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("implemented or approved")
  end

  it "rejects a manual visual review request when visual review is not configured" do
    configure_visual_review(enabled: false)
    finish_initial_workflow!
    job.update_columns(state: "implemented")

    expect { post app_job_path("/visual_review"), as: :json }.not_to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("not configured")
  end

  it "queues a manual before/after visual comparison workflow" do
    configure_visual_review(enabled: true)
    finish_initial_workflow!
    job.update_columns(state: "implemented")
    Workflow.create!(job:, trigger_kind: "manual_visual_review", state: "succeeded", artifacts: {
      "visual_review_iterations" => [ { "iteration" => 1, "verdict" => "approved", "artifacts" => [ {
        "type" => "visual_review_screenshot_run_1_1", "title" => "Dashboard",
        "image_url" => "/api/v1/app/workflows/1/visual_artifact?type=visual_review_screenshot_run_1_1"
      } ] } ]
    })

    expect { post app_job_path("/visual_diff"), as: :json }
      .to change { job.reload.workflows.where(trigger_kind: "visual_diff").count }.by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Before/after comparison enqueued.")
  end

  it "rejects a manual comparison when no after screenshots exist" do
    configure_visual_review(enabled: true)
    finish_initial_workflow!
    job.update_columns(state: "implemented")

    expect { post app_job_path("/visual_diff"), as: :json }.not_to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("No visual review screenshots")
  end
end
