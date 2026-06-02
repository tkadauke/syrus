require "rails_helper"

RSpec.describe App::SetupStatus do
  it "points a new first user at credentials" do
    user = Factories.user

    payload = described_class.call(user: user)

    expect(payload[:complete]).to eq(false)
    expect(payload[:next_step]).to eq("credentials")
    expect(payload.dig(:credentials, :ready)).to eq(false)
    expect(payload.dig(:system, :ready)).to eq(true)
    expect(payload.dig(:repositories, :active_count)).to eq(0)
    expect(payload.dig(:progress, :completed)).to eq(0)
  end

  it "advances through repository, first job, and watch states" do
    user = Factories.user(github_token: "ghp_test", claude_oauth_token: "oat-test")
    expect(described_class.call(user: user)[:next_step]).to eq("repository")

    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    repository_payload = described_class.call(user: user)
    expect(repository_payload[:next_step]).to eq("first_job")
    expect(repository_payload.dig(:repositories, :first, :slug)).to eq("acme/widgets")
    expect(repository_payload.dig(:repositories, :first, :credential_mode)).to eq("pat")

    job = Factories.job_record(user: user, repository: repository, issue_number: 7, issue_title: "First task", state: "running")
    watch_payload = described_class.call(user: user)
    expect(watch_payload[:next_step]).to eq("watch_job")
    expect(watch_payload.dig(:first_job, :job, :title)).to eq("First task")

    job.update!(state: "closed", closure_reason: "pr_merged")
    complete_payload = described_class.call(user: user)
    expect(complete_payload[:complete]).to eq(true)
    expect(complete_payload[:next_step]).to eq("complete")
    expect(complete_payload.dig(:progress, :completed)).to eq(4)
  end
end
