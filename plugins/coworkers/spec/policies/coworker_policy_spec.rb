require "rails_helper"

RSpec.describe CoworkerPolicy do
  let(:owner) { User.create!(email_address: "owner@example.com", password: "password123") }
  let(:other_user) { User.create!(email_address: "other@example.com", password: "password123") }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "git@example.com:workspaces.git") }

  it "routes every v1 action through ownership" do
    expect(described_class.new(owner, coworker)).to have_attributes(
      create?: true, show?: true, update?: true, destroy?: true, manage_grants?: true, manage_chats?: true
    )
    expect(described_class.new(other_user, coworker)).to have_attributes(
      create?: false, show?: false, update?: false, destroy?: false, manage_grants?: false, manage_chats?: false
    )
  end

  it "scopes records by coworker owner" do
    coworker
    Coworkers::Coworker.create!(owner_user: other_user, name: "Other", handle: "other-agent", workspace_repo: "git@example.com:other.git")

    expect(described_class::Scope.new(owner, Coworkers::Coworker).resolve).to contain_exactly(coworker)
  end
end
