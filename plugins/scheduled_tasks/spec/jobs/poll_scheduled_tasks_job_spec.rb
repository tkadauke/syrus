require "rails_helper"

RSpec.describe PollScheduledTasksJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def cron_task(**overrides)
    ScheduledTasks::Task.create!({
      user: user, repository: repository,
      name: "T", prompt: "p",
      kind: "cron", cron_expression: "0 * * * *",
      minute_offset: 1,
      pr_pileup_policy: "skip"
    }.merge(overrides))
  end

  def perform_poll
    perform_enqueued_jobs(only: ScheduledTasks::FireDueTaskJob) do
      described_class.perform_now
    end
  end

  it "fires due tasks via ScheduledTasks::Fire" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      task = cron_task
      task.update_columns(last_fired_at: 2.hours.ago)

      expect_any_instance_of(ScheduledTasks::Fire).to receive(:call)
        .and_return(ScheduledTasks::Fire::Result.new(job: nil, skipped: false, reason: nil))

      perform_poll
    end
  end

  it "leaves not-yet-due tasks alone" do
    freeze_time Time.current.change(min: 10, sec: 0, usec: 0) do
      task = cron_task
      now = Time.current
      task.update_columns(cron_expression: "#{now.min + 1} * * * *", last_fired_at: 1.minute.ago)

      expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
      perform_poll
    end
  end

  it "skips paused tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.pause!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    perform_poll
  end

  it "skips archived tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.soft_delete!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    perform_poll
  end

  it "skips tasks for archived repositories" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    repository.archive!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    perform_poll
  end

  it "skips tasks belonging to a user with scheduling paused" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    user.update!(scheduling_paused: true)

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    perform_poll
  end

  it "still fires tasks for other users when one user has scheduling paused" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      paused_user = Factories.user(scheduling_paused: true)
      paused_repo = Factories.repository(user: paused_user)
      paused_task = ScheduledTasks::Task.create!(
        user: paused_user, repository: paused_repo,
        name: "Paused", prompt: "p",
        kind: "cron", cron_expression: "0 * * * *",
        minute_offset: 1,
        pr_pileup_policy: "skip"
      )
      paused_task.update_columns(last_fired_at: 2.hours.ago)

      active_task = cron_task
      active_task.update_columns(last_fired_at: 2.hours.ago)

      fired_tasks = []
      allow_any_instance_of(ScheduledTasks::Fire).to receive(:call) do |svc|
        fired_tasks << svc.instance_variable_get(:@task)
        ScheduledTasks::Fire::Result.new(job: nil, skipped: false, reason: nil)
      end

      perform_poll

      expect(fired_tasks).to contain_exactly(active_task)
    end
  end

  it "isolates one bad task's failure from the rest of the pass" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      bad  = cron_task(name: "bad")
      good = cron_task(name: "good")
      bad.update_columns(last_fired_at: 2.hours.ago)
      good.update_columns(last_fired_at: 2.hours.ago)

      call_count = 0
      allow_any_instance_of(ScheduledTasks::Fire).to receive(:call) do
        call_count += 1
        raise "boom" if call_count == 1
        ScheduledTasks::Fire::Result.new(job: nil, skipped: false, reason: nil)
      end

      expect { perform_poll }.not_to raise_error
      expect(call_count).to eq(2)  # both tasks attempted
    end
  end

  it "durably records a failed fire and emits a backend exception event" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      task = cron_task
      task.update_columns(last_fired_at: 2.hours.ago)
      allow_any_instance_of(ScheduledTasks::Fire).to receive(:call).and_raise(ArgumentError, "broken handler")

      expect { perform_poll }.to change(BackendExceptionEvent, :count).by(1)

      expect(task.reload.consecutive_failure_count).to eq(1)
      expect(BackendExceptionEvent.last).to have_attributes(
        source: "active_job", job_class: ScheduledTasks::FireDueTaskJob.name,
        exception_class: "ArgumentError", message: "broken handler"
      )
    end
  end

  it "fans due tasks out without firing them inline" do
    now = Time.current.change(min: 2, sec: 0, usec: 0)
    tasks = Array.new(3) { |i| cron_task(name: "due #{i}").tap { |task| task.update_columns(last_fired_at: 2.hours.ago) } }

    freeze_time now do
      expect(ScheduledTasks::Fire).not_to receive(:new)

      expect { described_class.perform_now }
        .to have_enqueued_job(ScheduledTasks::FireDueTaskJob).exactly(3).times
    end

    enqueued_ids = enqueued_jobs.filter_map do |job|
      next unless job.fetch(:job) == ScheduledTasks::FireDueTaskJob

      ActiveJob::Arguments.deserialize(job.fetch(:args)).first.id
    end
    expect(enqueued_ids).to match_array(tasks.map(&:id))
  end

  describe "poll-wide database failures" do
    before { allow_any_instance_of(described_class).to receive(:sleep) }

    def due_task
      task = cron_task
      task.update_columns(last_fired_at: 2.hours.ago)
      task
    end

    def fire_result
      ScheduledTasks::Fire::Result.new(job: nil, skipped: false, reason: nil)
    end

    it "uses a consumed queue" do
      expect(described_class.new.queue_name).to eq("polling")
    end

    it "does not join or sort when scanning candidates" do
      freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
        due_task
        sqls = []
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| sqls << p[:sql] }
        allow_any_instance_of(ScheduledTasks::Fire).to receive(:call).and_return(fire_result)
        perform_poll
        ActiveSupport::Notifications.unsubscribe(sub)
        scan = sqls.select { |q| q =~ /FROM "scheduled_tasks"/ }
        expect(scan).not_to be_empty
        expect(scan.join).not_to match(/JOIN/i)
        expect(scan.join).to match(/LIMIT/i)
      end
    end

    # MySQL-only: SQLite has no filesort. Skipped on other adapters; runs where
    # the test database is MySQL. The cursor page must be served in primary-key
    # order from an index (no filesort), over a production-shaped volume of
    # tasks spread across repositories and users.
    it "plans the cursor page without a filesort on MySQL at volume" do
      skip "MySQL-only EXPLAIN check" unless ActiveRecord::Base.connection.adapter_name =~ /mysql|trilogy/i

      repos = Array.new(5) { Factories.repository }
      now = Time.current
      template = cron_task.attributes.except("id")
      rows = Array.new(2_000) do |i|
        template.merge(
          "repository_id" => repos[i % 5].id, "user_id" => repos[i % 5].user_id,
          "name" => "bulk #{i}", "system_key" => nil, "created_at" => now, "updated_at" => now
        )
      end
      ScheduledTasks::Task.insert_all(rows)
      # No ANALYZE TABLE: it implicitly commits on MySQL and would leak the
      # fixture rows out of the transactional example.

      relation = ScheduledTasks::Task.alive.where(state: "scheduled")
                                     .where(ScheduledTasks::Task.arel_table[:id].gt(0))
                                     .order(:id).limit(described_class::BATCH_SIZE)
      plan = relation.explain.inspect
      expect(plan).not_to match(/filesort/i)
      expect(plan).not_to match(/Using temporary/i)
    end

    [
      ["sort memory", -> { ActiveRecord::StatementInvalid.new("Mysql2::Error: Out of sort memory, consider increasing server sort buffer size") }],
      ["lock wait", -> { ActiveRecord::LockWaitTimeout.new("Lock wait timeout exceeded") }]
    ].each do |label, error|
      it "retries a transient #{label} failure and then fires the due task once" do
        freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
          due_task
          calls = 0
          original = ScheduledTasks::Task.method(:alive)
          allow(ScheduledTasks::Task).to receive(:alive) do
            calls += 1
            raise error.call if calls == 1
            original.call
          end
          fires = 0
          allow_any_instance_of(ScheduledTasks::Fire).to receive(:call) { fires += 1; fire_result }

          expect { perform_poll }.not_to raise_error
          expect(fires).to eq(1)
        end
      end
    end

    it "pages through tasks in bounded primary-key pages without skipping any" do
      stub_const("PollScheduledTasksJob::BATCH_SIZE", 2)
      tasks = Array.new(5) { |i| cron_task(name: "t#{i}").tap { |t| t.update_columns(last_fired_at: 2.hours.ago) } }
      seen = []
      allow_any_instance_of(described_class).to receive(:process_task) { |_, t, _| seen << t.id }

      described_class.new.perform

      expect(seen).to eq(tasks.map(&:id).sort)
    end

    it "raises an attributed failure once retries are exhausted and fires nothing" do
      freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
        due_task
        allow(ScheduledTasks::Task).to receive(:alive)
          .and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
        expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
        expect(Rails.logger).to receive(:error)
          .with(/phase=load_page attempts=3 outcome=retries_exhausted ActiveRecord::LockWaitTimeout/)

        expect { described_class.new.perform }
          .to raise_error(described_class::ScanFailed, /load_page.*retries_exhausted.*3 attempt/)
      end
    end

    it "does not retry non-transient database errors" do
      allow(ScheduledTasks::Task).to receive(:alive)
        .and_raise(ActiveRecord::StatementInvalid, "syntax error")
      expect { described_class.new.perform }
        .to raise_error(described_class::ScanFailed, /non_transient.*1 attempt/)
      expect(ScheduledTasks::Task).to have_received(:alive).once
    end

    it "fires a task missed during a failed poll exactly once after recovery" do
      freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
        task = due_task
        allow(ScheduledTasks::Task).to receive(:alive)
          .and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
        expect { described_class.new.perform }.to raise_error(described_class::ScanFailed)
        expect(task.reload.last_fired_at).to be < 1.hour.ago

        RSpec::Mocks.space.proxy_for(ScheduledTasks::Task).reset
        perform_poll
        perform_poll
        expect(Job.where(kind: "cron").count).to eq(1)
      end
    end
  end

  describe "system schedules" do
    # Due only through the definition's catch-up policy: the scheduled cron
    # window has already fired this hour, so `due?` hinges on the definition.
    let(:catch_up_definition) do
      Class.new(ScheduledTasks::SystemSchedules::Definition) do
        def prompt(task:, target_date:) = "catch up #{task.id}"
        def catch_up_due?(task:, now:) = true
      end
    end
    let(:now) { Time.utc(2026, 11, 4, 3, 30) }

    def system_task(key)
      cron_task(name: "System #{key}", prompt: nil, system_key: key).tap do |task|
        task.update_columns(last_fired_at: now - 25.minutes)
      end
    end

    def forget_definition(key)
      ScheduledTasks::SystemSchedules.send(:definitions).delete(key)
    end

    # Regression: a definition registered by a plugin install was invisible
    # to a process that had not synced the installer yet. The poller's
    # `due?` swallowed the resulting "unknown system schedule" as not due,
    # so the catch-up never fired and nothing was logged.
    it "syncs plugin installs before evaluating a system schedule that is due only by catch-up" do
      key = "spec_registered_on_sync"
      forget_definition(key)
      definition = catch_up_definition
      allow(Syrus::Host::Installer).to receive(:sync!).and_wrap_original do |original|
        ScheduledTasks::SystemSchedules.register(key, definition: definition)
        original.call
      end
      task = system_task(key)

      travel_to(now) do
        expect { described_class.perform_now }
          .to have_enqueued_job(ScheduledTasks::FireDueTaskJob).with(task, anything)
      end
    ensure
      forget_definition(key)
    end

    it "records an unregistered system schedule as a visible failure, once per hour" do
      key = "spec_never_registered"
      forget_definition(key)
      task = system_task(key)
      ordinary = cron_task(name: "ordinary").tap { |t| t.update_columns(last_fired_at: now - 2.hours) }
      exceptions_before = BackendExceptionEvent.count
      logged = []
      allow(Rails.logger).to receive(:error).and_wrap_original { |original, msg| logged << msg; original.call(msg) }

      travel_to(now) do
        expect { described_class.perform_now }
          .to have_enqueued_job(ScheduledTasks::FireDueTaskJob).with(ordinary, anything)
      end

      expect(logged).to include(a_string_matching(/task ##{task.id} system_key="#{key}".*unknown system schedule/))
      expect(task.reload.consecutive_failure_count).to eq(1)
      expect(task.occurrences.sole).to have_attributes(due_at: Time.utc(2026, 11, 4, 3), failed_at: now, completed_at: nil)
      expect(BackendExceptionEvent.count).to eq(exceptions_before + 1)
      expect(BackendExceptionEvent.last).to have_attributes(
        exception_class: ScheduledTasks::SystemSchedules::UnknownSystemSchedule.name,
        message: "unknown system schedule: #{key}"
      )

      # The next minute's poll still logs, but does not inflate the count.
      travel_to(now + 1.minute) { described_class.perform_now }
      expect(task.reload.consecutive_failure_count).to eq(1)
      expect(BackendExceptionEvent.count).to eq(exceptions_before + 1)
      expect(logged.grep(/task ##{task.id} system_key/).size).to eq(2)

      # A new hour is a new failure. (Its own scheduled window has already
      # been attempted, so only the catch-up check can make it due.)
      task.update_columns(last_fired_at: now + 1.hour - 25.minutes)
      travel_to(now + 1.hour) { described_class.perform_now }
      expect(task.reload.consecutive_failure_count).to eq(2)
      expect(task.occurrences.count).to eq(2)
    end

    it "keeps reading a definition's argument errors as quietly not due" do
      key = "spec_argument_error"
      definition = Class.new(ScheduledTasks::SystemSchedules::Definition) do
        def prompt(task:, target_date:) = "never"
        def catch_up_due?(task:, now:) = raise(ArgumentError, "unparseable schedule")
      end
      ScheduledTasks::SystemSchedules.register(key, definition: definition)
      task = system_task(key)

      travel_to(now) do
        expect { described_class.perform_now }.not_to have_enqueued_job(ScheduledTasks::FireDueTaskJob)
      end
      expect(task.reload.consecutive_failure_count).to eq(0)
      expect(task.occurrences).to be_empty
    ensure
      forget_definition(key)
    end
  end
end
