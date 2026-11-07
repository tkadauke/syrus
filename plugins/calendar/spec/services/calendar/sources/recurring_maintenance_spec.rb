require "rails_helper"

RSpec.describe Calendar::Sources::RecurringMaintenance do
  it "does not expose system maintenance to non-admins" do
    user = Factories.user
    user.update!(global_role: "user")
    expect(described_class.calendar_events(user:, starts_at: Time.current, ends_at: 1.day.from_now)).to be_empty
  end

  let(:admin) { Factories.user(admin: true) }
  let(:starts_at) { Time.zone.parse("2026-11-02 00:00:00") }
  let(:ends_at) { starts_at + 1.day }

  it "renders high-frequency administrator schedules as a single cadence band" do
    allow(described_class).to receive(:definitions).and_return("poll" => { "class" => "PollJob", "queue" => "polling", "schedule" => "every 5 minutes" })
    allow(described_class).to receive(:execution_observations_by_class).and_return({})

    events = described_class.calendar_events(user: admin, starts_at:, ends_at:)

    expect(events.one?).to be(true)
    event = events.first
    expect(event.cadence).to eq(label: "every 5 minutes", band: true)
    expect(event.starts_at).to eq(starts_at)
    expect(event.ends_at).to eq(ends_at)
    expect(event.destination_path).to eq("/admin/queues")
  end

  it "expands lower-frequency schedules at their actual planned times" do
    allow(described_class).to receive(:definitions).and_return("hourly" => { "class" => "HourlyJob", "schedule" => "every hour at minute 12" })
    allow(described_class).to receive(:execution_observations_by_class).and_return({})

    events = described_class.calendar_events(user: admin, starts_at:, ends_at: starts_at + 3.hours)

    expect(events.map(&:starts_at)).to eq([
      Time.zone.parse("2026-11-02 00:12:00"), Time.zone.parse("2026-11-02 01:12:00"), Time.zone.parse("2026-11-02 02:12:00")
    ])
    expect(events).to all(have_attributes(cadence: include(band: false)))
  end

  it "marks failed executions for operator attention" do
    job = SolidQueue::Job.create!(class_name: "HourlyJob", queue_name: "default", priority: 0,
      active_job_id: SecureRandom.uuid, created_at: starts_at + 12.minutes, updated_at: starts_at + 13.minutes,
      finished_at: starts_at + 13.minutes)
    SolidQueue::FailedExecution.create!(job:, error: "boom", created_at: starts_at + 13.minutes)
    allow(described_class).to receive(:definitions).and_return("hourly" => { "class" => "HourlyJob", "schedule" => "every hour at minute 12" })

    event = described_class.calendar_events(user: admin, starts_at:, ends_at: starts_at + 1.hour).first

    expect(event.state).to eq("attention")
    expect(event.actual_started_at).to eq(job.created_at)
    expect(event.metadata[:duration_seconds]).to eq(60.0)
  end

  it "bounds loaded execution history independently for each recurring class" do
    classes = %w[FastJob OtherJob]
    (described_class::MAX_OBSERVATIONS_PER_CLASS + 1).times do |index|
      SolidQueue::Job.create!(class_name: classes.first, queue_name: "default", priority: 0,
        active_job_id: SecureRandom.uuid, created_at: starts_at + index.seconds, updated_at: starts_at + index.seconds)
    end
    SolidQueue::Job.create!(class_name: classes.last, queue_name: "default", priority: 0,
      active_job_id: SecureRandom.uuid, created_at: starts_at, updated_at: starts_at)

    observations = described_class.execution_observations_by_class(classes, starts_at, ends_at)

    expect(observations.fetch(classes.first).size).to eq(described_class::MAX_OBSERVATIONS_PER_CLASS)
    expect(observations.fetch(classes.first).map { |item| item.fetch(:started_at) }).not_to include(starts_at)
    expect(observations.fetch(classes.last).size).to eq(1)
  end
end
