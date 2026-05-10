require "rails_helper"

RSpec.describe Steps::Push do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42, pr_number: 9) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:step) { Step.create!(workflow: workflow, kind: "push", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment", agent_provider: "claude") }

  it "replaces the managed PR cost footer after follow-up pushes" do
    job.initial_run.update!(cost_usd: 0.10)
    run.update!(cost_usd: 0.20)
    client = instance_double(GithubClient)
    existing_body = PrCostFooter.apply("Original body", job)

    allow(GithubClient).to receive(:for).with(user).and_return(client)
    allow(client).to receive(:pull_request)
      .with("acme/widgets", 9, bypass_cache: true)
      .and_return(Struct.new(:body).new(existing_body))

    expect(client).to receive(:update_pull_request_body) do |slug, pr_number, body|
      expect(slug).to eq("acme/widgets")
      expect(pr_number).to eq(9)
      expect(body.scan("This PR was implemented by Syrus").size).to eq(1)
      expect(body).to include("across 2 Runs at a total cost of $0.30")
    end

    described_class.new(run).send(:update_pr_cost_footer)
  end
end
