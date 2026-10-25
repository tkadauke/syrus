require "rails_helper"

RSpec.describe JobVisibility do
  let!(:admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before { RepositoryMembership.create!(repository: repository, user: member, role: "read") }

  it "does not change repository visibility when no restriction is registered" do
    job = Factories.job_record(repository: repository)

    expect(Job.visible_to(member)).to contain_exactly(job)
  end

  it "limits a registered origin while leaving every other origin visible" do
    allowed = Factories.job_record(repository: repository, origin: "private_tasks", origin_id: "11")
    hidden = Factories.job_record(repository: repository, origin: "private_tasks", origin_id: "12", issue_number: 43)
    ordinary = Factories.job_record(repository: repository, issue_number: 44)

    with_job_visibility_restriction(origin: "private_tasks", visible_origin_ids: ->(user) { user == owner ? %w[11 12] : %w[11] }) do
      expect(Job.visible_to(member)).to contain_exactly(allowed, ordinary)
      expect(Job.visible_to(owner)).to contain_exactly(allowed, hidden, ordinary)
    end
  end

  it "lets admins bypass origin restrictions when the caller supplies an admin scope" do
    hidden = Factories.job_record(repository: repository, origin: "private_tasks", origin_id: "12")

    with_job_visibility_restriction(origin: "private_tasks", visible_origin_ids: []) do
      expect(Job.visible_to(admin, scope: Job.all)).to include(hidden)
    end
  end

  it "rejects ambiguous restrictions for the same origin" do
    provider = Class.new { include Syrus::Plugin::JobVisibilityRestriction }
    provider.define_singleton_method(:origin_key) { "private_tasks" }
    provider.define_singleton_method(:visible_origin_ids) { |user:| [] }

    with_job_visibility_restriction(origin: "private_tasks", visible_origin_ids: []) do
      Syrus::PluginRegistry.register(:job_visibility_restriction, provider)
      expect { Job.visible_to(member).load }.to raise_error(described_class::DuplicateRestriction)
    end
  end
end
