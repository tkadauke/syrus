require "rails_helper"

RSpec.describe MainBranchHealth::WorkflowKinds do
  it "registers the main_grader and main_branch_repair workflows through the workflow-kind registry" do
    expect(Workflow::TriggerKind.values).to include("main_grader", "main_branch_repair")
    expect(Workflow::TriggerKind.template_for("main_grader")).to eq(Workflows::MainGrader)
    expect(Workflow::TriggerKind.template_for("main_branch_repair")).to eq(Workflows::MainBranchRepair)
    expect(Job::Kind.values).to include("main_grader")
    expect(Job::Kind.entries.find { |entry| entry.kind == "main_grader" }).to have_attributes(infrastructure: true, issueless: true)
  end

  it "registers plugin-owned work definitions" do
    expect(WorkDefinitions.registry.fetch("main_grader")).to be(MainBranchHealth::GraderWorkDefinition)
    expect(WorkDefinitions.registry.fetch("main_branch_repair")).to be(MainBranchHealth::RepairWorkDefinition)
    expect(MainBranchHealth::GraderWorkDefinition.plugin).to eq("main_branch_health")
  end

  it "keeps main grades from taking the repository landing mutex" do
    job = Factories.job_record
    keys = MainBranchHealth::GraderWorkDefinition.new.lock_keys_for(job: job, member_jobs: [ job ])

    expect(keys).to include("main_grader:repository:#{job.repository_id}")
    expect(keys).not_to include("repository:#{job.repository_id}")
  end
end
