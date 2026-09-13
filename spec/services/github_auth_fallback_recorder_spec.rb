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
