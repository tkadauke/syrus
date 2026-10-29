require "rails_helper"

RSpec.describe StackRebasePlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def epic
    Factories.epic(user: user, repository: repository, epic_dependency_policy: "linear")
  end

  def stack_job(epic:, number:, parent: nil)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: number,
      branch_name: "syrus/issue-#{number}",
      pr_number: number,
      parent_job: parent
    )
  end

  it "traverses anchored downstream Epics in dependency order when enabled" do
    allow(Feature).to receive(:early_epic_dependency_execution_enabled?).and_return(true)
    epic_a, epic_b, epic_c = 3.times.map { epic }
    EpicDependency.create!(epic: epic_b, depends_on_epic: epic_a)
    EpicDependency.create!(epic: epic_c, depends_on_epic: epic_b)
    a_root = stack_job(epic: epic_a, number: 11)
    a_tail = stack_job(epic: epic_a, number: 12, parent: a_root)
    b_root = stack_job(epic: epic_b, number: 21, parent: a_tail)
    b_tail = stack_job(epic: epic_b, number: 22, parent: b_root)
    c_root = stack_job(epic: epic_c, number: 31, parent: b_tail)

    artifacts = described_class.artifacts_for(job: a_root, base_branch: "main")

    expect(artifacts.fetch(described_class::STACK_ARTIFACT).map { |entry| [ entry["job_id"], entry["base_branch"] ] }).to eq([
      [ a_root.id, "main" ],
      [ a_tail.id, a_root.branch_name ],
      [ b_root.id, a_tail.branch_name ],
      [ b_tail.id, b_root.branch_name ],
      [ c_root.id, b_tail.branch_name ]
    ])
    expect(described_class.ordered_jobs_for(b_root)).to eq([ b_root, b_tail, c_root ])
    expect(described_class.lock_jobs_for(b_root)).to eq([ b_root, b_tail, c_root, a_tail ])
  end

  it "preserves single-Epic traversal when the feature is disabled" do
    allow(Feature).to receive(:early_epic_dependency_execution_enabled?).and_return(false)
    epic_a, epic_b = 2.times.map { epic }
    a_root = stack_job(epic: epic_a, number: 41)
    a_tail = stack_job(epic: epic_a, number: 42, parent: a_root)
    stack_job(epic: epic_b, number: 43, parent: a_tail)

    expect(described_class.ordered_jobs_for(a_root)).to eq([ a_root, a_tail ])
    expect(described_class.related_job_ids_for(a_tail)).to eq([ a_root.id, a_tail.id ])
  end
end
