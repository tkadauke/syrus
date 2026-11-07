require "rails_helper"

RSpec.describe Calendar::Sources::RecurringMaintenance do
  it "does not expose system maintenance to non-admins" do
    user = Factories.user
    user.update!(global_role: "user")
    expect(described_class.calendar_events(user:, starts_at: Time.current, ends_at: 1.day.from_now)).to be_empty
  end

  it "renders high-frequency administrator schedules as cadence bands" do
    admin = Factories.user(admin: true)
    allow(described_class).to receive(:definitions).and_return("poll" => { "class" => "PollJob", "queue" => "polling", "schedule" => "every 5 minutes" })
    allow(described_class).to receive(:execution_observation).and_return(state: "planned")

    event = described_class.calendar_events(user: admin, starts_at: Time.current, ends_at: 1.day.from_now).first

    expect(event.cadence).to eq(label: "every 5 minutes", band: true)
    expect(event.destination_path).to eq("/admin/queues")
  end
end
