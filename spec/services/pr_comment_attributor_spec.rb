require "rails_helper"

RSpec.describe PrCommentAttributor do
  let(:owner) { Factories.user(github_handle: "alice") }
  let(:repo) { Factories.repository(user: owner) }
  let(:job) { Factories.job(user: owner, repository: repo, issue_number: 10) }

  def call(github_handle)
    described_class.call(github_handle: github_handle, job: job)
  end

  it "attributes job owner's handle as job_owner" do
    expect(call("alice")).to eq("job_owner")
  end

  it "is case-insensitive for job owner matching" do
    expect(call("Alice")).to eq("job_owner")
    expect(call("ALICE")).to eq("job_owner")
  end

  it "strips @ prefix from handle before matching" do
    expect(call("@alice")).to eq("job_owner")
  end

  it "attributes a repository member as member" do
    member = Factories.user(github_handle: "bob")
    repo.repository_memberships.create!(user: member, role: "collaborator")

    expect(call("bob")).to eq("member")
  end

  it "attributes an unknown handle as external" do
    expect(call("carol")).to eq("external")
  end

  it "returns external for blank handle" do
    expect(call("")).to eq("external")
    expect(call(nil)).to eq("external")
  end

  it "uses owner_user when present and different from user" do
    owner2 = Factories.user(github_handle: "dave")
    job.update!(owner_user: owner2)

    expect(call("dave")).to eq("job_owner")
    # alice is the repo creator so she is a repository member; member < job_owner
    expect(call("alice")).to eq("member")
  end

  it "falls back to job.user when owner_user is nil" do
    job.update!(owner_user: nil)
    expect(call("alice")).to eq("job_owner")
  end

  it "attributes job owner who is also a member as job_owner" do
    # The owner membership seed means alice is already a member of the repo.
    # job_owner takes precedence over member.
    expect(call("alice")).to eq("job_owner")
  end
end
