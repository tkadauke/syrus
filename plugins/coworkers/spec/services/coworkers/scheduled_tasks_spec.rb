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

  def allow_schedule_tool
    definition = Coworkers::ChatToolSet.tool_definitions(tier: :essential)
      .find { |item| item[:name] == "manage_coworker_schedule" }
    descriptor = Permissions::CapabilityDescriptorAdapter.for_plugin_definition(definition)
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
      subject_role_keys: [], capability: descriptor.capability, operation: descriptor.operation,
      resource_type: descriptor.resource_scope.type.to_s, resource_scope: {}, constraints: {},
      policy: "allow", policy_layer: "agent", source: "operator", provenance: {}
    )
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

  it "reconciles exactly one code-owned journaling schedule and recreates it" do
    first = Coworkers::SystemSchedules.reconcile!(coworker)
    second = Coworkers::SystemSchedules.reconcile!(coworker)

    expect(second).to eq(first)
    expect(first).to have_attributes(system_key: "journaling", name: "Journaling", kind: "cron", after_run: "quiet")
    expect(first.prompt).to be_nil
    first.delete

    expect { Coworkers::SystemSchedules.reconcile!(coworker) }
      .to change { coworker.schedules.where(system_key: "journaling").count }.from(0).to(1)
  end

  it "uses the owner's general time zone instead of approval delivery preferences" do
    coworker.owner_user.update!(time_zone: "Europe/Berlin", approval_delivery_preferences: { "time_zone" => "America/Los_Angeles" })

    expect(Coworkers::SystemSchedules.reconcile!(coworker).schedule_timezone).to eq("Europe/Berlin")
  end

  it "rejects deletion and system-owned edits but permits pause and resume" do
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)

    expect { journaling.soft_delete! }.to raise_error(ActiveRecord::RecordInvalid, /System schedules cannot be deleted/)
    expect { journaling.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(journaling.errors.full_messages).to include("System schedules cannot be deleted.")
    expect(journaling.update(prompt: "Ignore your diary", kind: "one_shot", system_key: "other")).to be(false)
    expect(journaling.errors.full_messages.join).to include("owned by Syrus")

    journaling.reload.pause!
    expect(journaling).to be_paused
    journaling.resume!
    expect(journaling).to be_active
  end

  it "records a dormant journal date without creating a Job or invoking an agent" do
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)
    allow(WorkUnits::Launcher).to receive(:instantiate)

    travel_to(Time.utc(2026, 11, 4, 1, 0)) do
      result = ScheduledTasks::Fire.new(journaling).call

      expect(result).to have_attributes(skipped: true, reason: "dormant", job: nil)
      expect(journaling.reload).to have_attributes(
        last_journaled_on: Date.new(2026, 11, 3), last_system_result: "skipped", last_system_result_reason: "dormant"
      )
      expect(journaling.system_result_history).to include(
        "date" => "2026-11-03", "result" => "skipped", "reason" => "dormant"
      )
    end
    expect(WorkUnits::Launcher).not_to have_received(:instantiate)
  end

  it "counts a pending local daily-memory change as activity before it is pushed" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      path = root.join("memory/daily/2026-11-03.md")
      path.dirname.mkpath
      path.write("- A pending decision\n")
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(root)

      activity = Coworkers::JournalingActivity.new(coworker:, date: Date.new(2026, 11, 3))
      expect(activity).to be_active
      expect(activity.material).to include("A pending decision")
    end
  end

  it "does not follow daily-memory symlinks outside the coworker workspace" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    Dir.mktmpdir do |directory|
      root = Pathname(directory).join("workspace")
      path = root.join("memory/daily/2026-11-03.md")
      secret = Pathname(directory).join("secret.txt")
      path.dirname.mkpath
      secret.write("credential-store-secret")
      File.symlink(secret, path)
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(root)

      activity = Coworkers::JournalingActivity.new(coworker:, date: Date.new(2026, 11, 3))
      expect(activity).not_to be_active
      expect(activity.material).not_to include("credential-store-secret")
    end
  end

  it "does not follow symlinked directories in a daily-memory path" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    Dir.mktmpdir do |directory|
      root = Pathname(directory).join("workspace")
      outside = Pathname(directory).join("outside")
      root.join("memory").mkpath
      outside.mkpath
      outside.join("2026-11-03.md").write("other-workflow-secret")
      File.symlink(outside, root.join("memory/daily"))
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(root)

      activity = Coworkers::JournalingActivity.new(coworker:, date: Date.new(2026, 11, 3))
      expect(activity).not_to be_active
      expect(activity.material).not_to include("other-workflow-secret")
    end
  end

  it "fires an active journal date with the code-owned dated prompt" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)
    workflow = instance_double(Workflow, set_artifact!: true)
    allow(WorkUnits::Launcher).to receive(:instantiate).and_return(workflow)

    travel_to(Time.utc(2026, 11, 4, 1, 0)) do
      chat.messages.create!(role: "user", content: { "text" => "We decided something." }, skip_turn_trigger: true,
                            created_at: Time.utc(2026, 11, 3, 12))
      expect(WorkUnits::Launcher).to receive(:start!).with(workflow, prompt: include(
        "private nightly journaling for 2026-11-03", "CHAT-#{chat.id}", "memory/diary/2026-11-03.md"
      ))

      result = ScheduledTasks::Fire.new(journaling).call
      expect(result).to be_fired
      expect(result.job.issue_title).to end_with("for 2026-11-03")
    end
  end

  it "processes the oldest bounded catch-up batch in order without dropping earlier days" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)
    journaling.update_columns(last_journaled_on: Date.new(2026, 10, 20))
    dates = (Date.new(2026, 10, 21)..Date.new(2026, 10, 27)).to_a
    dates.each do |date|
      chat.messages.create!(role: "user", content: { "text" => date.iso8601 }, skip_turn_trigger: true,
                            created_at: date.in_time_zone("UTC").noon)
    end
    workflows = dates.map { instance_double(Workflow, set_artifact!: true) }
    allow(WorkUnits::Launcher).to receive(:instantiate).and_return(*workflows)
    allow(WorkUnits::Launcher).to receive(:start!)

    travel_to(Time.utc(2026, 11, 4, 1)) do
      first = ScheduledTasks::Fire.new(journaling).call
      expect(first.job.issue_title).to end_with(dates.first.iso8601)
      dates.each_cons(2) do |completed, next_date|
        journaling.record_system_result!(date: completed, result: "journaled")
        job = Coworkers::ScheduledTaskFireHandler.new(journaling).fire_journaling_catch_up!(
          now: Time.current, remaining: 7, after_date: completed
        )
        expect(job.issue_title).to end_with(next_date.iso8601)
      end
    end

    expect(Job.where(scheduled_task_id: journaling.id).order(:created_at).pluck(:issue_title)).to eq(
      dates.map { |date| "Scheduled coworker task: Journaling for #{date}" }
    )
    expect(WorkUnits::Launcher).to have_received(:start!).exactly(7).times
  end

  it "uses the owner's local yesterday across DST and month boundaries" do
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)
    journaling.update_columns(schedule_timezone: "America/New_York", last_journaled_on: nil)

    expect(Coworkers::SystemSchedules.target_dates(journaling, now: Time.utc(2026, 11, 1, 4, 15)))
      .to eq([ Date.new(2026, 10, 31) ])
    expect(Coworkers::SystemSchedules.target_dates(journaling, now: Time.utc(2026, 11, 2, 5, 15)))
      .to eq([ Date.new(2026, 11, 1) ])
  end

  it "retries a failed date after later dates finish" do
    journaling = Coworkers::SystemSchedules.reconcile!(coworker)
    journaling.record_system_result!(date: Date.new(2026, 11, 1), result: "failed", reason: "push failed")
    journaling.record_system_result!(date: Date.new(2026, 11, 2), result: "journaled")

    expect(Coworkers::SystemSchedules.target_dates(journaling, now: Time.utc(2026, 11, 4, 1)))
      .to eq([ Date.new(2026, 11, 1), Date.new(2026, 11, 2), Date.new(2026, 11, 3) ])
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

  it "does not fire a schedule from a scheduled-run follow-up turn" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    scheduled_task = task
    followup_message = chat.messages.create!(
      role: "system",
      content: {
        "source" => Coworkers::AfterRunPolicy::Wake::SOURCE,
        "background_run_id" => 123,
        "text" => "Follow up on the scheduled run."
      },
      skip_turn_trigger: true
    )
    allow(ScheduledTasks::Fire).to receive(:new)
    allow_schedule_tool

    result = Coworkers::ManageScheduleTool.call(
      action: "fire_now", scheduled_task_id: scheduled_task.id,
      server_context: { chat_session: chat, current_message: followup_message }
    )

    expect(result).to be_error
    expect(result.content.to_s).to include("cannot fire another scheduled run")
    expect(ScheduledTasks::Fire).not_to have_received(:new)
  end

  it "does not fire a schedule when the follow-up is batched with other system notices" do
    chat = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    scheduled_task = task
    followup_message = chat.messages.create!(
      role: "system",
      content: {
        "source" => ChatQueuedMessagePromoter::BATCH_SOURCE,
        "notices" => [ { "source" => Coworkers::AfterRunPolicy::Wake::SOURCE } ],
        "text" => "Several notices are ready."
      },
      skip_turn_trigger: true
    )
    allow(ScheduledTasks::Fire).to receive(:new)
    allow_schedule_tool

    result = Coworkers::ManageScheduleTool.call(
      action: "fire_now", scheduled_task_id: scheduled_task.id,
      server_context: { chat_session: chat, current_message: followup_message }
    )

    expect(result).to be_error
    expect(ScheduledTasks::Fire).not_to have_received(:new)
  end
end
