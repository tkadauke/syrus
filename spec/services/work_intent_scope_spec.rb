require "rails_helper"

RSpec.describe WorkIntentScope do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".for" do
    it "resolves known scope_types to their policy class" do
      expect(described_class.for("job")).to be_a(WorkIntentScope::JobScope)
      expect(described_class.for("epic")).to be_a(WorkIntentScope::EpicScope)
      expect(described_class.for("repository")).to be_a(WorkIntentScope::RepositoryScope)
    end

    it "falls back to Base for an unrecognized scope_type" do
      expect(described_class.for("bogus")).to be_a(WorkIntentScope::Base)
    end
  end

  describe WorkIntentScope::Base do
    it "has no jobs requiring approval and no representative job" do
      expect(subject.jobs_requiring_approval(123)).to eq([])
      expect(subject.representative_job(scope_id: 123, repository_id: 456, snapshot_members: [])).to be_nil
    end
  end

  describe WorkIntentScope::JobScope do
    it "returns the scoped job and uses it as the representative job" do
      job = Factories.job_record(user: user, repository: repository)

      expect(subject.jobs_requiring_approval(job.id)).to eq([ job ])
      expect(subject.representative_job(scope_id: job.id, repository_id: repository.id, snapshot_members: [])).to eq(job)
    end
  end

  describe WorkIntentScope::EpicScope do
    it "returns open jobs under the epic, excluding closed ones" do
      epic = Factories.epic(user: user, repository: repository)
      open_job = Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 1)
      Factories.job_record(user: user, repository: repository, epic: epic, state: "closed", issue_number: 2)

      expect(subject.jobs_requiring_approval(epic.id)).to eq([ open_job ])
    end

    it "prefers the last snapshot member as the representative job" do
      epic = Factories.epic(user: user, repository: repository)
      older = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1)
      newer = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2)

      expect(subject.representative_job(scope_id: epic.id, repository_id: repository.id, snapshot_members: [ older, newer ])).to eq(newer)
      expect(subject.representative_job(scope_id: epic.id, repository_id: repository.id, snapshot_members: [])).to eq(newer)
    end
  end

  describe WorkIntentScope::RepositoryScope do
    it "has no jobs requiring approval (bundle membership isn't tracked on the intent)" do
      expect(subject.jobs_requiring_approval(repository.id)).to eq([])
    end

    it "prefers the first snapshot member, else the newest job in the repository" do
      older = Factories.job_record(user: user, repository: repository, issue_number: 1)
      newer = Factories.job_record(user: user, repository: repository, issue_number: 2)

      expect(subject.representative_job(scope_id: nil, repository_id: repository.id, snapshot_members: [ older, newer ])).to eq(older)
      expect(subject.representative_job(scope_id: nil, repository_id: repository.id, snapshot_members: [])).to eq(newer)
    end
  end
end
