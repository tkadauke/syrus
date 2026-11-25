require "rails_helper"

RSpec.describe AgentQuestions::FileFixJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository, priority: "high", needs_attention_reason: "agent_cannot_proceed") }

  it "files a repair Job and makes the blocked Job wait for it to land" do
    result = described_class.call(job: job, actor: user)

    expect(result.job).to have_attributes(kind: "direct", repository: repository, priority: "high")
    expect(result.job.issue_body).to include(job.slug, "agent_cannot_proceed")
    expect(job.dependencies.find_by!(depends_on_job: result.job)).to have_attributes(
      satisfaction_mode: "landed",
      source: "manual",
      created_by_user: user
    )
    expect(described_class.call(job: job, actor: user).job).to eq(result.job)
    expect(job.dependencies.count).to eq(1)
  end
end
