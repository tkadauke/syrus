require "rails_helper"

RSpec.describe WorkIntents::Scope do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def intent_for(scope_type:, scope_id:)
    WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: scope_type,
      scope_id: scope_id,
      actor: user,
      source_type: "spec"
    )
  end

  describe ".for" do
    it "returns a JobScope for scope_type 'job'" do
      intent = intent_for(scope_type: "job", scope_id: 1)

      expect(described_class.for(intent)).to be_a(WorkIntents::Scopes::JobScope)
    end

    it "returns an EpicScope for scope_type 'epic'" do
      intent = intent_for(scope_type: "epic", scope_id: 1)

      expect(described_class.for(intent)).to be_a(WorkIntents::Scopes::EpicScope)
    end

    it "returns a RepositoryScope for scope_type 'repository'" do
      intent = intent_for(scope_type: "repository", scope_id: repository.id)

      expect(described_class.for(intent)).to be_a(WorkIntents::Scopes::RepositoryScope)
    end

    it "raises ConfigurationError for unknown scope types" do
      intent = intent_for(scope_type: "job", scope_id: 1)
      intent.scope_type = "constellation"

      expect { described_class.for(intent) }
        .to raise_error(WorkIntents::Scope::ConfigurationError, /Unknown WorkIntent scope_type/)
    end
  end

  describe WorkIntents::Scopes::JobScope do
    it "resolves the single scoped job for approval and as the representative job" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      intent = intent_for(scope_type: "job", scope_id: job.id)

      scope = described_class.new(intent)

      expect(scope.jobs_requiring_approval).to eq([ job ])
      expect(scope.representative_job([])).to eq(job)
    end
  end

  describe WorkIntents::Scopes::EpicScope do
    it "requires approval from every non-closed child job, ordered as found" do
      epic = Factories.epic(user: user, repository: repository)
      open_job = Factories.job_record(user: user, repository: repository, epic: epic, state: "queued")
      Factories.job_record(user: user, repository: repository, epic: epic, state: "closed")
      intent = intent_for(scope_type: "epic", scope_id: epic.id)

      scope = described_class.new(intent)

      expect(scope.jobs_requiring_approval).to eq([ open_job ])
    end

    it "prefers the most recent snapshot member as the representative job" do
      epic = Factories.epic(user: user, repository: repository)
      older_member = Factories.job_record(user: user, repository: repository, epic: epic)
      newer_member = Factories.job_record(user: user, repository: repository, epic: epic)
      intent = intent_for(scope_type: "epic", scope_id: epic.id)

      scope = described_class.new(intent)

      expect(scope.representative_job([ older_member, newer_member ])).to eq(newer_member)
    end

    it "falls back to the newest child job when there is no snapshot" do
      epic = Factories.epic(user: user, repository: repository)
      Factories.job_record(user: user, repository: repository, epic: epic)
      latest = Factories.job_record(user: user, repository: repository, epic: epic)
      intent = intent_for(scope_type: "epic", scope_id: epic.id)

      scope = described_class.new(intent)

      expect(scope.representative_job([])).to eq(latest)
    end
  end

  describe WorkIntents::Scopes::RepositoryScope do
    it "never requires job approval" do
      intent = intent_for(scope_type: "repository", scope_id: repository.id)

      expect(described_class.new(intent).jobs_requiring_approval).to eq([])
    end

    it "prefers the first snapshot member as the representative job" do
      first_member = Factories.job_record(user: user, repository: repository)
      other_member = Factories.job_record(user: user, repository: repository)
      intent = intent_for(scope_type: "repository", scope_id: repository.id)

      scope = described_class.new(intent)

      expect(scope.representative_job([ first_member, other_member ])).to eq(first_member)
    end

    it "falls back to the most recently created repository job when there is no snapshot" do
      Factories.job_record(user: user, repository: repository)
      latest = Factories.job_record(user: user, repository: repository)
      intent = intent_for(scope_type: "repository", scope_id: repository.id)

      scope = described_class.new(intent)

      expect(scope.representative_job([])).to eq(latest)
    end
  end
end
