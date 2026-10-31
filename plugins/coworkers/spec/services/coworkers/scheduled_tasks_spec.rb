require "rails_helper"

RSpec.describe "Coworker scheduled tasks" do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-schedules",
      workspace_repo: repository.remote_url
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
  end

  def task(**attributes)
    ScheduledTasks::Task.create!({
      user: owner, repository: repository, coworker_id: coworker.id,
      name: "Morning briefing", prompt: "Prepare my briefing.", kind: "cron",
      schedule_input: "Every day at 9:00 AM", pr_pileup_policy: "skip",
      auto_approve_mode: "never"
    }.merge(attributes))
  end

  it "fires a coworker Job and coworker workflow without PR behaviors" do
    scheduled_task = task
    workflow = instance_double(Workflow)
    allow(WorkUnits::Launcher).to receive(:instantiate).with(kind: "coworker_run", job: instance_of(Job)).and_return(workflow)
    allow(WorkUnits::Launcher).to receive(:start!).with(workflow, prompt: scheduled_task.prompt)

    result = ScheduledTasks::Fire.new(scheduled_task).call

    expect(result).to be_fired
    expect(result.job).to have_attributes(
      kind: "coworker_task", origin: "coworkers", origin_id: coworker.id.to_s,
      scheduled_task_id: scheduled_task.id, repository_id: repository.id
    )
    expect(ScheduledTasks::FireHandlers.for(scheduled_task).applicable_behaviors).to be_empty
  end

  it "applies the shared one-hour minimum interval" do
    too_frequent = ScheduledTasks::Task.new(
      user: owner, repository: repository, coworker_id: coworker.id,
      name: "Too frequent", prompt: "Brief me.", kind: "cron",
      schedule_input: "*/30 * * * *", pr_pileup_policy: "skip", auto_approve_mode: "never"
    )

    expect(too_frequent).not_to be_valid
    expect(too_frequent.errors[:schedule_input].join).to match(/hour/i)
  end

  it "auto-pauses without firing when workspace write access is missing" do
    scheduled_task = task
    repository.repository_memberships.where(user: owner).delete_all
    allow(RepositoryPolicy).to receive(:new).with(owner, repository).and_return(instance_double(RepositoryPolicy, write?: false))

    result = ScheduledTasks::Fire.new(scheduled_task).call

    expect(result).to have_attributes(skipped: true, reason: "repository_write_access_required", job: nil)
    expect(scheduled_task.reload).to be_auto_paused
  end

  it "removes schedules when their plugin-owned coworker is cleaned up" do
    scheduled_task = task

    coworker.destroy!

    expect(ScheduledTasks::Task.where(id: scheduled_task.id)).to be_empty
  end

  it "unregisters the fire handler when the plugin effect is disabled" do
    task
    scope = Syrus::EffectScope.new(label: "coworker schedule spec")
    entries = ScheduledTasks::FireHandlers.instance_variable_get(:@entries)
    before_count = entries.count
    Coworkers::ScheduleExtension.install_into(scope)
    expect(entries.count).to eq(before_count + 1)
    scope.dispose

    expect(entries.count).to eq(before_count)
  ensure
    scope&.dispose
  end

  it "lets the grant-gated coworker tool add and list only its own schedules" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    added = Coworkers::ManageScheduleTool.call(
      action: "add", name: "Weekly review", prompt: "Review the week.",
      kind: "cron", schedule_input: "Every Monday at 9:00 AM",
      server_context: { chat_session: chat }
    )

    expect(added).not_to be_error
    expect(coworker.schedules).to contain_exactly(have_attributes(name: "Weekly review", repository: repository, after_run: "wake"))
    expect(Coworkers::ManageScheduleTool.call(action: "list", server_context: { chat_session: chat })).not_to be_error
  end

  it "does not pause or resume a fired one-shot through the coworker tool" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    one_shot = task(
      kind: "one_shot", schedule_input: nil, fire_at: 1.hour.from_now,
      name: "Single briefing"
    )
    one_shot.update!(state: "fired")

    pause = Coworkers::ManageScheduleTool.call(
      action: "pause", scheduled_task_id: one_shot.id, server_context: { chat_session: chat }
    )
    resume = Coworkers::ManageScheduleTool.call(
      action: "resume", scheduled_task_id: one_shot.id, server_context: { chat_session: chat }
    )

    expect(pause).to be_error
    expect(resume).to be_error
    expect(one_shot.reload).to be_fired
  end
end
