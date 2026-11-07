require "rails_helper"

RSpec.describe "security review workflow loop" do
  it "materializes the configured number of repair/review iterations" do
    job = Factories.job
    loaded = RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new("security_review:\n  rounds: 3\n").parse,
      source: ".syrus.yml", note: nil
    )

    allow(RepoAdversarialReviewPlan).to receive(:from_syrus_yml).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
    allow(RepoCoworkerReviewPlan).to receive(:from_syrus_yml).and_return(double(enabled?: false))
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(double(enabled?: false, rounds: 0))

    loop_node = Workflows::Initial.review_gate_loops(job, agent_step: :implement, syrus_yml: loaded)
      .find { |loop| loop.steps.last == "security_review" }

    expect(loop_node.max_iterations).to eq(3)
    expect(loop_node.steps).to eq(%w[implement security_review])
  end
end
