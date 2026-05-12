require "rails_helper"

RSpec.describe JobDependency do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def issue_job(number)
    Job.create!(user: user, repository: repository, issue_number: number)
  end

  it "rejects self references" do
    job = issue_job(1)
    dependency = described_class.new(job: job, depends_on_job: job, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("can't be the same Job")
  end

  it "rejects a direct cycle" do
    a = issue_job(1)
    b = issue_job(2)
    described_class.create!(job: a, depends_on_job: b, source: "manual")

    dependency = described_class.new(job: b, depends_on_job: a, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("would create a cycle")
  end

  it "rejects an indirect cycle" do
    a = issue_job(1)
    b = issue_job(2)
    c = issue_job(3)
    described_class.create!(job: a, depends_on_job: b, source: "manual")
    described_class.create!(job: b, depends_on_job: c, source: "manual")

    dependency = described_class.new(job: c, depends_on_job: a, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("would create a cycle")
  end
end
