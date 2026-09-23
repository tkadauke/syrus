require "rails_helper"

RSpec.describe Revisionable do
  let(:user) { Factories.user }

  it "starts at entity_revision 1 after create and bumps by 1 on every subsequent save" do
    chat = ChatSession.create!(user: user)
    expect(chat.entity_revision).to eq(1)

    chat.update!(title: "Renamed")
    expect(chat.entity_revision).to eq(2)

    chat.update!(title: "Renamed again")
    expect(chat.entity_revision).to eq(3)
  end

  it "is included on every live entity the frontend entity store normalizes" do
    expect(Job.ancestors).to include(Revisionable)
    expect(Workflow.ancestors).to include(Revisionable)
    expect(Step.ancestors).to include(Revisionable)
    expect(Run.ancestors).to include(Revisionable)
    expect(ChatSession.ancestors).to include(Revisionable)
    expect(ChatMessage.ancestors).to include(Revisionable)
  end
end
