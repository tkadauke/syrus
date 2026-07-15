require "rails_helper"

RSpec.describe SmartFolder do
  it "creates the built-in folders as system-owned rows" do
    # 12 Job built-ins + 9 Epic + 4 Workflow + 4 Admin User
    # + 3 Spawned Process + 6 Admin Queue = 38.
    expect { described_class.ensure_builtins! }.to change(described_class, :count).by(38)

    expect(described_class::JOB_BUILTINS).to eq(described_class::BUILTIN_DEFINITIONS)
    expect(described_class::EPIC_BUILTINS).to eq(described_class::EPIC_BUILTIN_DEFINITIONS)
    expect(described_class::WORKFLOW_BUILTINS).to eq(described_class::WORKFLOW_BUILTIN_DEFINITIONS)
    expect(described_class::ADMIN_USER_BUILTINS).to eq(described_class::ADMIN_USER_BUILTIN_DEFINITIONS)
    expect(described_class::ADMIN_QUEUE_BUILTINS).to eq(described_class::ADMIN_QUEUE_BUILTIN_DEFINITIONS)
    expect(described_class::SPAWNED_PROCESS_BUILTINS).to eq(described_class::SPAWNED_PROCESS_BUILTIN_DEFINITIONS)
    expect(described_class.builtins.pluck(:name)).to eq([
      "Pinned",
      "In progress",
      "Queued",
      "Invalid",
      "Awaiting Epic",
      "Inbox",
      "Landing queue",
      "Just failed",
      "Blocked",
      "Stale",
      "Merged this week",
      "All jobs"
    ])
    expect(described_class.builtins.pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins.pluck(:subject_type).uniq).to eq([ "job" ])
    expect(described_class.builtins(:epic).pluck(:name)).to eq([
      "My epics",
      "Claimable",
      "In progress",
      "Ready",
      "Blocked",
      "Stalled",
      "Empty",
      "Recently done",
      "Archived"
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
    expect(described_class.builtins(:admin_user).pluck(:name)).to eq([
      "Admins",
      "Missing GitHub token",
      "Missing Claude token",
      "Rate limit low"
    ])
    expect(described_class.builtins(:admin_user).pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins(:admin_user).pluck(:subject_type).uniq).to eq([ "admin_user" ])
    expect(described_class.builtins(:admin_queue).pluck(:name)).to eq([
      "Failed today",
      "Failed this hour",
      "Runs",
      "Chat",
      "Default",
      "Merges"
    ])
    expect(described_class.builtins(:admin_queue).pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins(:admin_queue).pluck(:subject_type).uniq).to eq([ "admin_queue" ])
    expect(described_class.builtins(:spawned_process).pluck(:name)).to eq([
      "Running",
      "Stale",
      "Recently failed"
    ])
    expect(described_class.builtins(:spawned_process).pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins(:spawned_process).pluck(:subject_type).uniq).to eq([ "spawned_process" ])
  end

  it "can ensure only one built-in subject" do
    expect { described_class.ensure_builtins_for_subject!(:job) }
      .to change(described_class, :count).by(described_class::JOB_BUILTINS.size)

    expect(described_class.distinct.pluck(:subject_type)).to eq([ "job" ])
    expect(described_class.builtins(:job).pluck(:name)).to eq(described_class::JOB_BUILTINS.map { |definition| definition.fetch(:name) })
    expect(described_class.builtins(:epic)).to be_empty
  end

  it "sweeps retired built-ins on next ensure_builtins!" do
    described_class.create!(name: "Ghost", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)
    described_class.create!(name: "Ghost", subject_type: "epic", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)
    described_class.create!(name: "Ghost", subject_type: "workflow", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)
    described_class.create!(name: "Ghost", subject_type: "spawned_process", kind: "builtin", filter: { "field" => "stale", "op" => "is", "value" => "true" }, position: 99)

    expect { described_class.ensure_builtins! }.to change { described_class.exists?(name: "Ghost") }.from(true).to(false)
  end

  it "classifies built-in visibility tiers" do
    described_class.ensure_builtins!
    by_name = described_class.builtins.to_h { |f| [ f.name, f.visibility ] }

    expect(by_name["Inbox"]).to eq(:always)
    expect(by_name["Landing queue"]).to eq(:when_present)
    expect(by_name["Pinned"]).to eq(:when_present)
    expect(by_name["Queued"]).to eq(:when_present)
    expect(by_name["Invalid"]).to eq(:when_present)
    expect(by_name["Awaiting Epic"]).to eq(:when_present)
    expect(by_name["Stale"]).to eq(:on_demand)
    expect(by_name["Merged this week"]).to eq(:on_demand)
    expect(by_name).not_to have_key("In review")
    expect(by_name).not_to have_key("Needs review")

    epic_by_name = described_class.builtins(:epic).to_h { |f| [ f.name, f.visibility ] }
    expect(epic_by_name["In progress"]).to eq(:always)
    expect(epic_by_name["Ready"]).to eq(:when_present)
    expect(epic_by_name["Empty"]).to eq(:on_demand)
    expect(epic_by_name["Archived"]).to eq(:on_demand)

    workflow_by_name = described_class.builtins(:workflow).to_h { |f| [ f.name, f.visibility ] }
    expect(workflow_by_name["Running"]).to eq(:always)
    expect(workflow_by_name["Stuck"]).to eq(:when_present)
    expect(workflow_by_name["Just failed"]).to eq(:when_present)
    expect(workflow_by_name["Queued"]).to eq(:on_demand)

    admin_user_by_name = described_class.builtins(:admin_user).to_h { |f| [ f.name, f.visibility ] }
    expect(admin_user_by_name["Admins"]).to eq(:on_demand)
    expect(admin_user_by_name["Missing GitHub token"]).to eq(:when_present)

    admin_queue_by_name = described_class.builtins(:admin_queue).to_h { |f| [ f.name, f.visibility ] }
    expect(admin_queue_by_name["Failed today"]).to eq(:always)
    expect(admin_queue_by_name["Failed this hour"]).to eq(:when_present)

    spawned_process_by_name = described_class.builtins(:spawned_process).to_h { |f| [ f.name, f.visibility ] }
    expect(spawned_process_by_name["Running"]).to eq(:always)
    expect(spawned_process_by_name["Stale"]).to eq(:when_present)
  end

  it "accepts admin subject types" do
    user = Factories.user

    %w[admin_user admin_queue spawned_process].each do |subject_type|
      folder = described_class.new(
        user: user,
        name: "#{subject_type} folder",
        kind: "user_defined",
        subject_type: subject_type,
        filter: { "field" => "state", "op" => "is", "value" => "running" }
      )

      expect(folder).to be_valid
    end
  end

  it "seeds admin user built-ins idempotently" do
    described_class.ensure_admin_user_builtins!

    expect(described_class.builtins(:admin_user).pluck(:name)).to eq([
      "Admins",
      "Missing GitHub token",
      "Missing Claude token",
      "Rate limit low"
    ])
    expect {
      described_class.ensure_admin_user_builtins!
    }.not_to change { described_class.for_subject(:admin_user).count }
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

  it "applies the Missing GitHub token admin user built-in through Admin::Users::Filter" do
    with_token = Factories.user(email_address: "token@example.com", github_token: "ghp_x")
    without_token = Factories.user(email_address: "missing@example.com")
    described_class.ensure_admin_user_builtins!

    folder = described_class.builtins(:admin_user).find_by!(name: "Missing GitHub token")
    result = Admin::Users::Filter.from_tree(folder.filter, user: without_token).apply(User.all)

    expect(result).to include(without_token)
    expect(result).not_to include(with_token)
  end

  it "seeds the Archived Epic built-in as an on-demand state filter" do
    described_class.ensure_epic_builtins!

    archived = described_class.builtins(:epic).find_by!(name: "Archived")

    expect(archived.visibility).to eq(:on_demand)
    expect(archived.filter).to eq(
      "and" => [
        { "field" => "state", "op" => "is", "value" => "archived" }
      ]
    )
  end

  it "compiles each workflow built-in filter against Workflow.all" do
    queued = workflow_with_state("queued")
    running = workflow_with_state("running")
    stuck = workflow_with_state("running")
    failed = workflow_with_state("failed", finished_at: Time.current)
    workflow_with_state("succeeded", finished_at: Time.current)

    mark_workflow_run_running(running, last_heartbeat_at: Time.current, started_at: Time.current)
    stale_at = (Run::STALE_HEARTBEAT_THRESHOLD + 1.minute).ago
    mark_workflow_run_running(stuck, last_heartbeat_at: stale_at, started_at: stale_at)
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
