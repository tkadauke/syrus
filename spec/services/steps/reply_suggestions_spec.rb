require "rails_helper"

RSpec.describe Steps::ReplySuggestions do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job(repository: repository).tap do |j|
      j.update!(pr_number: 7)
    end
  end
  let(:workflow) do
    Workflow.create!(
      job: job,
      trigger_kind: "pr_comment",
      artifacts: {
        "applied_suggestions" => [
          { "comment_id" => 123, "commit_sha" => "abcdef1234567890" }
        ]
      }
    )
  end
  let(:step) { Step.create!(workflow: workflow, kind: "reply_suggestions", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment") }

  it "replies to each auto-applied review comment thread with the pushed commit" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(user).and_return(client)
    expect(client).to receive(:reply_to_pr_review_comment)
      .with("acme/widgets", 7, 123, "Applied suggested change in abcdef1.")

    described_class.new(run).call
  end
end
