require "rails_helper"

RSpec.describe GithubAuthFallbackRecorder do
  class GithubAuthFallbackRecorderSpecError < StandardError
    def response_status = 404
  end

  let(:user) { Factories.user }
  let(:installation) { Factories.installation(user: user, github_installation_id: 1234) }
  let(:repository) { Factories.repository(user: user, installation: installation) }
  let(:error) { GithubAuthFallbackRecorderSpecError.new("Not Found") }

  it "coalesces identical recent diagnostics to avoid hot diagnostic writes" do
    described_class.record!(
      repository: repository,
      installation: installation,
      operation_type: "api",
      error: error,
      refresh_attempted: true,
      refresh_succeeded: true
    )

    expect {
      described_class.record!(
        repository: repository,
        installation: installation,
        operation_type: "api",
        error: error,
        refresh_attempted: true,
        refresh_succeeded: true
      )
    }.not_to change(GithubAuthFallbackDiagnostic, :count)
  end

  it "updates current Job credential mode even when diagnostic writes coalesce" do
    job = Factories.job(repository: repository, user: user, kind: "main_grader", issue_number: nil, credential_mode: "app")
    workflow = job.workflows.create!(user: user, trigger_kind: "main_grader", agent_provider: job.agent_provider)
    step = workflow.steps.create!(kind: "implement", position: 1)
    run = step.runs.create!(job: job, user: user, trigger_kind: workflow.trigger_kind)
    described_class.record!(
      repository: repository,
      installation: installation,
      operation_type: "api",
      error: error,
      refresh_attempted: true,
      refresh_succeeded: true,
      run: run
    )
    job.update!(credential_mode: "app")

    expect {
      described_class.record!(
        repository: repository,
        installation: installation,
        operation_type: "api",
        error: error,
        refresh_attempted: true,
        refresh_succeeded: true,
        run: run
      )
    }.not_to change(GithubAuthFallbackDiagnostic, :count)
    expect(job.reload.credential_mode).to eq("pat")
  end

  it "records a fresh diagnostic after the coalescing window" do
    GithubAuthFallbackDiagnostic.create!(
      repository: repository,
      installation: installation,
      github_installation_id: installation.github_installation_id,
      operation_type: "api",
      error_class: "GithubAuthFallbackRecorderSpecError",
      error_status: 404,
      error_message: "Not Found",
      refresh_attempted: true,
      refresh_succeeded: true,
      created_at: 11.minutes.ago,
      updated_at: 11.minutes.ago
    )

    expect {
      described_class.record!(
        repository: repository,
        installation: installation,
        operation_type: "api",
        error: error,
        refresh_attempted: true,
        refresh_succeeded: true
      )
    }.to change(GithubAuthFallbackDiagnostic, :count).by(1)
  end
end
