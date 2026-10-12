require "rails_helper"

RSpec.describe MergeTrainMultisect, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:owner_job) { members.last.job }
  let(:workflow) do
    Workflow.create!(
      job: owner_job,
      trigger_kind: "merge_train",
      artifacts: {
        "merge_train_id" => train.id,
        GraderLoopProgress::ARTIFACT_KEY => [
          { "iteration" => 1, "failing_set" => [ "spec/widgets_spec.rb\u0000Widget fails" ] }
        ]
      }
    )
  end
  let(:train) do
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master").tap do |record|
      member_count.times do |index|
        job = Factories.job_record(
          user: user,
          repository: repository,
          epic: epic,
          issue_number: index + 1,
          state: "landing",
          pr_number: 500 + index,
          branch_name: "syrus/issue-#{index + 1}"
        )
        MergeTrainMember.create!(merge_train: record, job: job, position: index)
      end
    end
  end
  let(:members) { train.members.includes(:job).order(:position).to_a }
  let(:member_count) { 14 }

  def evaluator_for(&block)
    lambda do |members:, role:, **|
      MergeTrainMultisect::Evaluation.new(block.call(members, role), "stubbed", {})
    end
  end

  def call_multisect(evaluator:, section_width: 4, determinism_gate: double(reproducible?: true, payload: {}))
    described_class.call(
      workflow: workflow,
      train: train,
      section_width: section_width,
      evaluator: evaluator,
      determinism_gate: determinism_gate,
      log: ->(_message) { }
    )
  end

  it "isolates a single culprit using n-way rounds rather than one grade per member" do
    culprit = members[5]
    evaluated_sections = []
    evaluator = evaluator_for do |section, role|
      evaluated_sections << section unless role == "oracle"
      section.include?(culprit)
    end

    result = call_multisect(evaluator: evaluator)

    expect(result).to be_attributed
    expect(result.member).to eq(culprit)
    expect(result.rounds.size).to eq(2)
    expect(evaluated_sections.size).to be < member_count
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)["attributed_member"]["job_id"]).to eq(culprit.job_id)
  end

  it "aborts when the focused oracle does not reproduce against the full assembly" do
    evaluator = evaluator_for { |_section, _role| false }

    result = call_multisect(evaluator: evaluator)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("oracle_did_not_reproduce")
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)["reason"]).to eq("oracle_did_not_reproduce")
  end

  it "does not attribute when the reproducibility gate flags a flaky oracle" do
    gate = double(reproducible?: false, payload: { "gate" => "known_flaky_failure" })
    evaluator = evaluator_for { |_section, _role| true }

    result = call_multisect(evaluator: evaluator, determinism_gate: gate)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("flaky_oracle")
  end

  it "escalates an interaction failure when two disjoint sections reproduce" do
    first_culprit = members[1]
    second_culprit = members[7]
    evaluator = evaluator_for do |section, role|
      role == "oracle" || section.include?(first_culprit) || section.include?(second_culprit)
    end

    result = call_multisect(evaluator: evaluator)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("multiple_sections_reproduced")
  end

  it "checks the omitted section before attributing a graded reproducing section" do
    graded_culprit = members[1]
    omitted_culprit = members.last
    evaluator = evaluator_for do |section, role|
      role == "oracle" || section.include?(graded_culprit) || section.include?(omitted_culprit)
    end

    result = call_multisect(evaluator: evaluator)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("multiple_sections_reproduced")
  end

  it "aborts instead of attributing the omitted section when every graded section is clean" do
    evaluated_roles = []
    evaluator = evaluator_for do |_section, role|
      evaluated_roles << role
      role == "oracle"
    end

    result = call_multisect(evaluator: evaluator)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("no_subset_reproduced")
    expect(evaluated_roles).to eq([ "oracle", "section", "section", "section" ])
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)["reason"]).to eq("no_subset_reproduced")
  end

  it "treats an empty focused selector as a failure to reproduce, not a pass" do
    workflow.update!(artifacts: { "merge_train_id" => train.id, GraderLoopProgress::ARTIFACT_KEY => [] })
    evaluator = evaluator_for { |_section, _role| true }

    result = call_multisect(evaluator: evaluator)

    expect(result).not_to be_attributed
    expect(result.reason).to eq("empty_focused_selector")
  end
end
