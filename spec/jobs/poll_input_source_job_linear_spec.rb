require "rails_helper"

RSpec.describe "PollInputSourceJob with Linear source" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:source) do
    InputSources::Linear.create!(
      repository: repository,
      user: user,
      polling_enabled: true,
      config: { "team_id" => "TEAM-ABC" },
      credentials: { "api_key" => "lin_api_test_key" }
    )
  end

  def linear_issue(id: "linear-uuid-1", identifier: "LIN-1", title: "Do the thing", description: "body text", state_type: "started")
    {
      "id" => id,
      "identifier" => identifier,
      "title" => title,
      "description" => description,
      "state" => { "type" => state_type },
      "labels" => { "nodes" => [] }
    }
  end

  it "creates a Job end-to-end via PollInputSourceJob" do
    allow_any_instance_of(LinearClient).to receive(:issues).and_return([ linear_issue ])

    expect { PollInputSourceJob.perform_now(source.id) }.to change(Job, :count).by(1)

    job = Job.last
    expect(job.issue_title).to eq("Do the thing")
    expect(job.external_ref).to eq("linear-uuid-1")
    expect(job.input_source_id).to eq(source.id)
    expect(job.repository).to eq(repository)
  end

  it "does not create a Job for a cancelled issue" do
    cancelled = linear_issue(state_type: "cancelled")
    allow_any_instance_of(LinearClient).to receive(:issues).and_return([ cancelled ])

    expect { PollInputSourceJob.perform_now(source.id) }.not_to change(Job, :count)
  end

  it "skips when polling is disabled unless forced" do
    source.update!(polling_enabled: false)
    allow_any_instance_of(LinearClient).to receive(:issues).and_return([ linear_issue ])

    expect { PollInputSourceJob.perform_now(source.id) }.not_to change(Job, :count)
  end

  it "calls poll! on a disabled source when force: true (bypasses job guard; poll! still checks polling_enabled)" do
    source.update!(polling_enabled: false)
    allow(InputSource).to receive(:find_by).with(id: source.id).and_return(source)

    expect(source).to receive(:poll!)
    PollInputSourceJob.perform_now(source.id, force: true)
  end
end
