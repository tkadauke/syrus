require "rails_helper"

RSpec.describe PollScheduledTasksJob do
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

  it "fires due tasks via ScheduledTasks::Fire" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      task = cron_task
      task.update_columns(last_fired_at: 2.hours.ago)

      expect_any_instance_of(ScheduledTasks::Fire).to receive(:call)
        .and_return(ScheduledTasks::Fire::Result.new(job: nil, skipped: false, reason: nil))

      described_class.perform_now
    end
  end

  it "leaves not-yet-due tasks alone" do
    freeze_time Time.current.change(min: 10, sec: 0, usec: 0) do
      task = cron_task
      now = Time.current
      task.update_columns(cron_expression: "#{now.min + 1} * * * *", last_fired_at: 1.minute.ago)

      expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
      described_class.perform_now
    end
  end

  it "skips paused tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.pause!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips archived tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.soft_delete!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips tasks for archived repositories" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    repository.archive!

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips tasks belonging to a user with scheduling paused" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    user.update!(scheduling_paused: true)

    expect_any_instance_of(ScheduledTasks::Fire).not_to receive(:call)
    described_class.perform_now
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

      described_class.perform_now

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

      expect { described_class.perform_now }.not_to raise_error
      expect(call_count).to eq(2)  # both tasks attempted
    end
  end

  it "durably records a failed fire and emits a backend exception event" do
    freeze_time Time.current.change(min: 2, sec: 0, usec: 0) do
      task = cron_task
      task.update_columns(last_fired_at: 2.hours.ago)
      allow_any_instance_of(ScheduledTasks::Fire).to receive(:call).and_raise(ArgumentError, "broken handler")

      expect { described_class.perform_now }.to change(BackendExceptionEvent, :count).by(1)

      expect(task.reload.consecutive_failure_count).to eq(1)
      expect(BackendExceptionEvent.last).to have_attributes(
        source: "active_job", job_class: described_class.name,
        exception_class: "ArgumentError", message: "broken handler"
      )
    end
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
        described_class.perform_now
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
      rows = Array.new(2_000) do |i|
        cron_task.attributes.except("id").merge(
          "repository_id" => repos[i % 5].id, "user_id" => repos[i % 5].user_id,
          "name" => "bulk #{i}", "system_key" => nil, "created_at" => now, "updated_at" => now
        )
      end
      ScheduledTasks::Task.insert_all(rows)
      ActiveRecord::Base.connection.execute("ANALYZE TABLE scheduled_tasks")

      relation = ScheduledTasks::Task.alive.where(state: "scheduled")
                                     .where(ScheduledTasks::Task.arel_table[:id].gt(0))
                                     .order(:id).limit(described_class::BATCH_SIZE)
      plan = relation.explain.to_s
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

          expect { described_class.perform_now }.not_to raise_error
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
        described_class.perform_now
        described_class.perform_now
        expect(Job.where(kind: "cron").count).to eq(1)
      end
    end
  end
end
