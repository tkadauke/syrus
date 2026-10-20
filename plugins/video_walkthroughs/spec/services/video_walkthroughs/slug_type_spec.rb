require "rails_helper"

RSpec.describe VideoWalkthroughs::SlugType do
  let(:owner) { Factories.user }
  let(:chat) { ChatSession.create!(user: owner) }
  let(:walkthrough) do
    VideoWalkthroughs::Walkthrough.new(
      chat_session: chat,
      user: owner,
      state: "analyzed",
      byte_size: 12,
      content_type: "video/mp4",
      duration_seconds: 5
    ).tap do |record|
      record.file.attach(io: StringIO.new("video"), filename: "walkthrough.mp4", content_type: "video/mp4")
      record.save!
    end
  end

  it "resolves an accessible walkthrough to its anchored chat media entry" do
    expect(described_class.record_for(walkthrough.id, user: owner)).to eq(walkthrough)
    expect(described_class.client_path(walkthrough.id)).to eq("/s/WALKTHROUGH-#{walkthrough.id}")
    expect(described_class.web_path(walkthrough)).to eq("/chats/#{chat.id}#walkthrough-#{walkthrough.id}")
  end

  it "does not expose walkthroughs from inaccessible chats" do
    outsider = Factories.user(email_address: "outsider@example.com")

    expect(described_class.record_for(walkthrough.id, user: outsider)).to be_nil
  end
end
