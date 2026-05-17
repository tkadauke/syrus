require "rails_helper"

RSpec.describe SmartFolder do
  it "creates the built-in folders as system-owned rows" do
    # 11 Job built-ins (post "In review" removal) + 6 Epic + 4 Workflow = 21.
    expect { described_class.ensure_builtins! }.to change(described_class, :count).by(21)

    expect(described_class::JOB_BUILTINS).to eq(described_class::BUILTIN_DEFINITIONS)
    expect(described_class::EPIC_BUILTINS).to eq(described_class::EPIC_BUILTIN_DEFINITIONS)
    expect(described_class::WORKFLOW_BUILTINS).to eq(described_class::WORKFLOW_BUILTIN_DEFINITIONS)
    expect(described_class.builtins.pluck(:name)).to eq([
      "Pinned",
      "In progress",
      "Invalid",
      "Awaiting Epic",
      "Inbox",
      "Awaiting your approval",
      "Landing queue",
      "Just failed",
      "Blocked",
      "Stale",
      "Merged this week"
    ])
    expect(described_class.builtins.pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins.pluck(:subject_type).uniq).to eq([ "job" ])
    expect(described_class.builtins(:epic).pluck(:name)).to eq([
      "In progress",
      "Ready",
      "Blocked",
      "Stalled",
      "Empty",
      "Recently done"
    ])
    expect(described_class.builtins(:epic).pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins(:epic).pluck(:subject_type).uniq).to eq([ "epic" ])
    expect(described_class.builtins(:workflow).pluck(:name)).to eq([
      "Running",
      "Stuck",
      "Just failed",
      "Queued"
    ])
    expect(described_class.builtins(:workflow).pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins(:workflow).pluck(:subject_type).uniq).to eq([ "workflow" ])
  end

  it "sweeps retired built-ins on next ensure_builtins!" do
    described_class.create!(name: "Ghost", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)
    described_class.create!(name: "Ghost", subject_type: "epic", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)
    described_class.create!(name: "Ghost", subject_type: "workflow", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)

    expect { described_class.ensure_builtins! }.to change { described_class.exists?(name: "Ghost") }.from(true).to(false)
  end

  it "classifies built-in visibility tiers" do
    described_class.ensure_builtins!
    by_name = described_class.builtins.to_h { |f| [ f.name, f.visibility ] }

    expect(by_name["Inbox"]).to eq(:always)
    expect(by_name["Landing queue"]).to eq(:when_present)
    expect(by_name["Pinned"]).to eq(:when_present)
    expect(by_name["Invalid"]).to eq(:when_present)
    expect(by_name["Awaiting Epic"]).to eq(:when_present)
    expect(by_name["Stale"]).to eq(:when_present)
    expect(by_name["Merged this week"]).to eq(:on_demand)
    expect(by_name).not_to have_key("In review")
    expect(by_name).not_to have_key("Needs review")

    epic_by_name = described_class.builtins(:epic).to_h { |f| [ f.name, f.visibility ] }
    expect(epic_by_name["In progress"]).to eq(:always)
    expect(epic_by_name["Ready"]).to eq(:when_present)
    expect(epic_by_name["Empty"]).to eq(:on_demand)

    workflow_by_name = described_class.builtins(:workflow).to_h { |f| [ f.name, f.visibility ] }
    expect(workflow_by_name["Running"]).to eq(:always)
    expect(workflow_by_name["Stuck"]).to eq(:when_present)
    expect(workflow_by_name["Just failed"]).to eq(:when_present)
    expect(workflow_by_name["Queued"]).to eq(:on_demand)
  end

  it "seeds workflow built-ins idempotently without touching user-defined workflow folders" do
    user = Factories.user
    user_folder = described_class.create!(
      user: user,
      name: "Running",
      kind: "user_defined",
      subject_type: "workflow",
      filter: { "field" => "state", "op" => "is", "value" => "running" },
      position: 99
    )

    described_class.ensure_workflow_builtins!

    expect {
      described_class.ensure_workflow_builtins!
    }.not_to change { described_class.for_subject(:workflow).count }
    expect(user_folder.reload.filter).to eq({ "field" => "state", "op" => "is", "value" => "running" })
    expect(user_folder.position).to eq(99)
  end

  it "defines workflow built-in filters as attention presets" do
    expect(described_class::WORKFLOW_BUILTINS.map { |d| [ d.fetch(:key), d.fetch(:filter) ] }).to eq([
      [ "workflows_running", described_class.workflow_attention("running") ],
      [ "workflows_stuck", described_class.workflow_attention("stuck") ],
      [ "workflows_just_failed", described_class.workflow_attention("just_failed") ],
      [ "workflows_queued", described_class.workflow_attention("queued") ]
    ])
  end

  it "compiles each workflow built-in filter against Workflow.all" do
    queued = workflow_with_state("queued")
    running = workflow_with_state("running")
    stuck = workflow_with_state("running")
    failed = workflow_with_state("failed", finished_at: Time.current)
    workflow_with_state("succeeded", finished_at: Time.current)

    mark_workflow_run_running(running, last_heartbeat_at: Time.current, started_at: Time.current)
    mark_workflow_run_running(stuck, last_heartbeat_at: 10.minutes.ago, started_at: 10.minutes.ago)
    described_class.ensure_workflow_builtins!

    results = described_class.builtins(:workflow).to_h do |folder|
      node = Filters::Ast.parse(folder.filter)
      [ folder.name, Filters::Compiler.call(node, scope: Workflow.all, subject: :workflow).to_a ]
    end

    expect(results.fetch("Running")).to contain_exactly(running, stuck)
    expect(results.fetch("Stuck")).to contain_exactly(stuck)
    expect(results.fetch("Just failed")).to contain_exactly(failed)
    expect(results.fetch("Queued")).to contain_exactly(queued)
  end

  it "requires user-defined folders to belong to a user" do
    folder = described_class.new(name: "Mine", kind: "user_defined", filter: { "state" => "open" })

    expect(folder).not_to be_valid
    expect(folder.errors[:user]).to include("must be present for user-defined smart folders")
  end

  it "allows a user to reuse a folder name across subjects" do
    user = Factories.user

    job_folder = described_class.create!(
      user: user,
      name: "In progress",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "open" }
    )
    epic_folder = described_class.create!(
      user: user,
      name: "In progress",
      kind: "user_defined",
      subject_type: "epic",
      filter: { "state" => "open" }
    )

    expect(described_class.for_subject(:job)).to include(job_folder)
    expect(described_class.for_subject(:epic)).to include(epic_folder)
  end

  it "keeps user folder names unique within a subject" do
    user = Factories.user
    described_class.create!(
      user: user,
      name: "Mine",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "open" }
    )

    duplicate = described_class.new(
      user: user,
      name: "Mine",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "closed" }
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to include("has already been taken")
  end

  def workflow_with_state(state, **attrs)
    workflow = Factories.job.workflows.first
    workflow.update_columns({ state: state }.merge(attrs))
    workflow.reload
  end

  def mark_workflow_run_running(workflow, started_at:, last_heartbeat_at:)
    run = workflow.runs.first
    run.update_columns(
      state: "running",
      started_at: started_at,
      last_heartbeat_at: last_heartbeat_at
    )
  end
end
