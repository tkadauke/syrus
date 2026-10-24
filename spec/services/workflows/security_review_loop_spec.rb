require "rails_helper"

RSpec.describe "security review workflow loop" do
  it "materializes the configured number of repair/review iterations" do
    job = Factories.job
    loaded = RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new("security_review:\n  rounds: 3\n").parse,
      source: ".syrus.yml", note: nil
    )

    loop_node = Workflows::Base.security_review_loop(job, agent_step: :implement, syrus_yml: loaded)

    expect(loop_node.max_iterations).to eq(3)
    expect(loop_node.steps).to eq(%w[implement security_review])
  end
end
