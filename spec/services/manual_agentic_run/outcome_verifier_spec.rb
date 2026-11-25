require "rails_helper"

RSpec.describe ManualAgenticRun::OutcomeVerifier do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, pr_number: 9, branch_name: "repair") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "manual_agentic_run", agent_provider: "codex") }
  let(:client) { instance_double(GithubClient) }

  it "independently verifies branch and pull-request outcomes" do
    workflow.set_artifact!("manual_agentic_run_expected_outcomes", {
      "remote_branch" => { "name" => "repair", "sha" => "a" * 40 },
      "pull_request" => { "number" => 9, "base" => "main", "state" => "open", "labels" => [ "repair" ], "comment_contains" => "verified repair" }
    })
    pr = double(base: double(ref: "main"), state: "open", labels: [ double(name: "repair") ])
    allow(client).to receive(:branch_head_sha).and_return("a" * 40)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_issue_comments).and_return([ double(id: 77, body: "verified repair complete") ])

    evidence = described_class.new(workflow, client: client).verify!

    expect(evidence.dig("remote_branch", "sha")).to eq("a" * 40)
    expect(evidence.dig("pull_request", "comment_id")).to eq(77)
    expect(client).to have_received(:pull_request).with(repository.slug, 9, bypass_cache: true)
  end

  it "fails a persuasive-summary false success and preserves recovery evidence" do
    workflow.set_artifact!("manual_agentic_run_expected_outcomes", {
      "remote_branch" => { "name" => "repair", "sha" => "a" * 40 }
    })
    allow(client).to receive(:branch_head_sha).and_return("b" * 40)

    expect { described_class.new(workflow, client: client).verify! }
      .to raise_error(described_class::VerificationFailed, /expected/)
    expect(workflow.reload.artifact("manual_agentic_run_publication_recovery")).to include(
      "branch" => "repair",
      "expected_outcomes" => hash_including("remote_branch")
    )
  end

  it "verifies publication against the recorded implementation HEAD" do
    step = Step.create!(workflow: workflow, kind: "manual_agentic_run", position: 0)
    Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: "codex", head_sha: "c" * 40)
    workflow.set_artifact!("manual_agentic_run_expected_outcomes", {
      "remote_branch" => { "name" => "repair", "sha" => "local_head" }
    })
    allow(client).to receive(:branch_head_sha).and_return("c" * 40)

    expect(described_class.new(workflow, client: client).verify!.dig("remote_branch", "sha")).to eq("c" * 40)
  end

  it "fails closed when the provider is unavailable" do
    workflow.set_artifact!("manual_agentic_run_expected_outcomes", {
      "remote_branch" => { "name" => "repair", "sha" => "a" * 40 }
    })
    allow(client).to receive(:branch_head_sha).and_raise(Octokit::ServerError)

    expect { described_class.new(workflow, client: client).verify! }
      .to raise_error(described_class::VerificationFailed)
  end
end
