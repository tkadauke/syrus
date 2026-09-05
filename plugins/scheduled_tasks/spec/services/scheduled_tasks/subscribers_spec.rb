require "rails_helper"

# The plugin's side of what used to be core callbacks: Job's close event
# reaching into ScheduledTask, a second record_failure! on the runaway path,
# and User#seed_default_cron_templates.
RSpec.describe ScheduledTasks::Subscribers do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:task) do
    ScheduledTasks::Task.create!(
      user: user, repository: repository, name: "Nightly sweep", kind: "cron",
      cron_expression: "0 9 * * 1", pr_pileup_policy: "skip", prompt: "survey"
    )
  end

  def event(overrides = {})
    { job_id: 1, origin: "scheduled_tasks", origin_id: task.id.to_s, closure_reason: nil }.merge(overrides)
  end

  describe "outcome propagation" do
    it "records a success for an ordinary close" do
      expect { described_class.on_job_closed(event(closure_reason: "pr_merged")) }
        .to change { task.reload.consecutive_failure_count }.by(0)
    end

    it "records a failure for a too-many-failures close" do
      expect { described_class.on_job_closed(event(closure_reason: "too_many_failures")) }
        .to change { task.reload.consecutive_failure_count }.by(1)
    end

    # Bookkeeping for the pile-replace policy: neither success nor failure.
    it "records nothing for a replaced close" do
      task.record_failure!
      expect { described_class.on_job_closed(event(closure_reason: "replaced_by_scheduled_task")) }
        .not_to change { task.reload.consecutive_failure_count }
    end

    it "ignores a Job that came from somewhere else" do
      expect { described_class.on_job_closed(event(origin: "github_source", origin_id: "42", closure_reason: "too_many_failures")) }
        .not_to change { task.reload.consecutive_failure_count }
    end

    # Runaway protection fails a Job without closing it, so this never arrives
    # as job.closed and the failure would otherwise go unrecorded.
    it "records a failure when runaway protection stops a Job" do
      expect { described_class.on_job_runaway_stopped(event(runaway_reason: "too_many_workflows")) }
        .to change { task.reload.consecutive_failure_count }.by(1)
    end

    it "survives a task that no longer exists" do
      expect { described_class.on_job_closed(event(origin_id: "999999")) }.not_to raise_error
    end
  end

  describe "template seeding" do
    it "seeds defaults for the installation's first user" do
      created = Factories.user

      described_class.on_user_created(user_id: created.id, first_user: true)

      expect(ScheduledTasks::CronTemplate.where(user_id: created.id).pluck(:name))
        .to contain_exactly("Deduplicate code", "Keep documentation up to date", "Increase test coverage")
    end

    it "seeds nothing for later signups" do
      created = Factories.user

      described_class.on_user_created(user_id: created.id, first_user: false)

      expect(ScheduledTasks::CronTemplate.where(user_id: created.id)).to be_empty
    end
  end

  # The whole point of routing through the event: core publishes, and this
  # plugin's subscriber is what does the seeding.
  it "is reached by the published user.created event" do
    created = Factories.user

    # Subscribers receive a Syrus::DomainEvent, which reads like a hash.
    expect(described_class).to receive(:on_user_created) do |event|
      expect(event[:user_id]).to eq(created.id)
      expect(event[:first_user]).to be(true)
    end

    perform_enqueued_jobs do
      Syrus::Events.publish("user.created", user_id: created.id, first_user: true)
    end
  end
end
