require "rails_helper"

RSpec.describe InputSources::Linear do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:source) do
    InputSources::Linear.create!(
      repository: repository,
      user: user,
      polling_enabled: true,
      config: { "team_id" => "TEAM-123", "label_filter" => nil },
      credentials: { "api_key" => "lin_api_test" }
    )
  end

  def linear_issue(id: "abc-1", identifier: "LIN-1", title: "Fix bug", description: "Details", state_type: "started")
    {
      "id" => id,
      "identifier" => identifier,
      "title" => title,
      "description" => description,
      "state" => { "type" => state_type },
      "labels" => { "nodes" => [] }
    }
  end

  describe "#config_schema" do
    it "returns team_id and label_filter field definitions" do
      schema = source.config_schema
      keys = schema.map { |f| f[:key] }
      expect(keys).to include("team_id", "label_filter")
    end

    it "marks team_id as required and label_filter as optional" do
      schema = source.config_schema
      team_id_field = schema.find { |f| f[:key] == "team_id" }
      label_filter_field = schema.find { |f| f[:key] == "label_filter" }
      expect(team_id_field[:required]).to be true
      expect(label_filter_field[:required]).to be false
    end
  end

  describe "#dedup_key" do
    it "returns the issue id string" do
      issue = linear_issue(id: "uuid-9999")
      expect(source.dedup_key(issue)).to eq("uuid-9999")
    end
  end

  describe "#label_filter" do
    it "returns nil when config has no label_filter" do
      expect(source.label_filter).to be_nil
    end

    it "returns the configured label filter when set" do
      source.config = source.config.merge("label_filter" => "syrus")
      expect(source.label_filter).to eq("syrus")
    end
  end

  describe "#validate_credentials!" do
    it "raises when api_key is blank" do
      source.credentials = { "api_key" => "" }
      expect { source.validate_credentials! }.to raise_error(/API key is required/)
    end

    it "raises with a meaningful message when LinearClient raises" do
      allow_any_instance_of(LinearClient).to receive(:viewer).and_raise("HTTP 401")
      expect { source.validate_credentials! }.to raise_error(/Linear credentials invalid/)
    end

    it "raises when viewer returns nil (rate-limited)" do
      allow_any_instance_of(LinearClient).to receive(:viewer).and_return(nil)
      expect { source.validate_credentials! }.to raise_error(/Invalid or rate-limited/)
    end

    it "does not raise when viewer returns a valid response" do
      allow_any_instance_of(LinearClient).to receive(:viewer).and_return({ "id" => "user-1" })
      expect { source.validate_credentials! }.not_to raise_error
    end
  end

  describe "#poll!" do
    it "creates a Job for a new issue" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ linear_issue ])

      expect { source.poll! }.to change(Job, :count).by(1)

      job = Job.last
      expect(job.issue_title).to eq("Fix bug")
      expect(job.issue_body).to eq("Details")
      expect(job.external_ref).to eq("abc-1")
      expect(job.input_source).to eq(source)
    end

    it "does not create a duplicate Job when already ingested" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ linear_issue ])
      source.poll!
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "skips issues whose state type is cancelled" do
      cancelled = linear_issue(state_type: "cancelled")
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ cancelled ])
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "skips issues whose state type is completed" do
      completed = linear_issue(state_type: "completed")
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ completed ])
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "does nothing when polling_enabled is false" do
      source.update!(polling_enabled: false)
      expect(LinearClient).not_to receive(:new)
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "records poll status ok on the repository after success" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([])
      source.poll!
      expect(repository.reload.last_poll_status).to eq("ok")
    end

    it "records poll failure on the repository when LinearClient raises" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_raise("Linear API error: unauthorized")
      expect { source.poll! }.to raise_error(/Linear API error/)
      expect(repository.reload.last_poll_status).to eq("failed")
      expect(repository.reload.last_poll_error).to include("unauthorized")
    end

    it "returns early without error when LinearClient returns nil (rate-limited)" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_return(nil)
      expect { source.poll! }.not_to raise_error
      expect(repository.reload.last_poll_status).to eq("ok")
    end

    it "raises when team_id is not configured" do
      source.config = source.config.merge("team_id" => "")
      allow_any_instance_of(LinearClient).to receive(:issues)
      expect { source.poll! }.to raise_error(/team ID is not configured/)
    end

    it "passes label_name to the client when label_filter is configured" do
      source.config = source.config.merge("label_filter" => "syrus")
      client_double = instance_double(LinearClient, issues: [])
      expect(LinearClient).to receive(:new).with(api_key: "lin_api_test").and_return(client_double)
      expect(client_double).to receive(:issues).with(team_id: "TEAM-123", label_name: "syrus").and_return([])
      source.poll!
    end

    it "ingests an Epic declaration without creating a Job" do
      epic_issue = linear_issue(description: "Epic: Big feature rollout")
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ epic_issue ])

      expect { source.poll! }.to change(Epic, :count).by(1).and change(Job, :count).by(0)

      epic = Epic.last
      expect(epic.title).to eq("Big feature rollout")
      expect(epic.repository).to eq(repository)
    end
  end

  describe "#issues_ingested_count" do
    it "returns 0 when no jobs have been ingested" do
      expect(source.issues_ingested_count).to eq(0)
    end

    it "counts jobs created by this source" do
      allow_any_instance_of(LinearClient).to receive(:issues).and_return([ linear_issue ])
      source.poll!
      expect(source.issues_ingested_count).to eq(1)
    end
  end
end
