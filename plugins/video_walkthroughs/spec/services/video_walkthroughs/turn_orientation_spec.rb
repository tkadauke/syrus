require "rails_helper"

RSpec.describe VideoWalkthroughs::TurnOrientation do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def message(content)
    ChatMessage.new(chat_session: chat_session, role: "user", content: content)
  end

  def walkthrough(**attrs)
    row = VideoWalkthroughs::Walkthrough.new(
      { chat_session: chat_session, user: user, content_type: "video/mp4", byte_size: 10,
        title: "Checkout run", state: "analyzed", analysis: { "summary" => "s" } }.merge(attrs)
    )
    row.file.attach(io: StringIO.new("mp4-bytes"), filename: "walkthrough.mp4", content_type: "video/mp4")
    row.save!
    row
  end

  it "claims a walkthrough message and orients the agent toward its own tools" do
    row = walkthrough

    text = described_class.chat_turn_orientation(
      chat_session: chat_session, message: message({ "video_walkthrough_id" => row.id }), user_note: "look at checkout"
    )

    expect(text).to be_present
    expect(text).to include("get_walkthrough_analysis")
  end

  it "leaves an ordinary message alone" do
    text = described_class.chat_turn_orientation(
      chat_session: chat_session, message: message("just a question"), user_note: "just a question"
    )

    expect(text).to be_nil
  end

  it "leaves a hash message with no walkthrough id alone" do
    text = described_class.chat_turn_orientation(
      chat_session: chat_session, message: message({ "text" => "hi" }), user_note: "hi"
    )

    expect(text).to be_nil
  end

  # The row can be gone (pruned, chat deleted mid-flight). Falling through to a
  # normal turn on whatever the user typed is what they meant either way.
  it "falls through when the walkthrough row has vanished" do
    text = described_class.chat_turn_orientation(
      chat_session: chat_session, message: message({ "video_walkthrough_id" => 999_999 }), user_note: "note"
    )

    expect(text).to be_nil
  end
end
