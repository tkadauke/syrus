require "rails_helper"

RSpec.describe BugReports::ChatStarter do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # `have_been_enqueued` reads the test adapter's process-wide enqueued_jobs
  # list, which nothing clears between examples. The assertion below was
  # therefore reading whatever an earlier spec in the run had enqueued, and
  # passed only when this file ran on its own.
  before { clear_enqueued_jobs }

  def upload(name:, content_type:, body:)
    Struct.new(:original_filename, :content_type, :body) do
      def read = body
    end.new(name, content_type, body)
  end

  it "does not leave an existing group chat turn in flight when the prompt does not trigger the agent" do
    chat_session = ChatSession.create!(
      user: user,
      repository: repository,
      conversation_kind: "group",
      last_message_at: Time.current
    )
    chat_session.chat_participants.create!(user: Factories.user, role: "member")
    allow(ChatSession).to receive(:create!).and_return(chat_session)

    result = nil
    expect {
      result = described_class.new(user: user, repository: repository).call(
        title: "Group chat bug",
        description: "Record this without waking the agent."
      )
    }.to change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTitleJob)

    expect(result).to be_success
    expect(chat_session.reload).not_to be_turn_in_flight
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "sanitizes accepted attachment basenames before creating the chat message" do
    result = described_class.new(user: user, repository: repository).call(
      title: "Attachment path",
      description: "Inspect it.",
      attachments: [ upload(name: "../../notes.txt", content_type: "text/plain", body: "safe text") ]
    )

    expect(result).to be_success
    expect(result.chat_session.messages.last.content.fetch("attachments")).to contain_exactly(
      include("name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64("safe text"))
    )
  end

  it "rejects invalid recognized text instead of inlining it into the prompt" do
    expect {
      result = described_class.new(user: user, repository: repository).call(
        title: "Binary text",
        description: "Inspect it.",
        attachments: [ upload(name: "notes.txt", content_type: "text/plain", body: "unsafe\0text") ]
      )

      expect(result).not_to be_success
      expect(result.error).to eq("notes.txt is not valid UTF-8 text.")
    }.not_to change(ChatSession, :count)
  end

  it "enforces the aggregate decoded attachment limit before creating a chat" do
    stub_const("ChatMessageParams::CHAT_ATTACHMENT_TOTAL_MAX_BYTES", 5)
    attachments = %w[first second].map do |name|
      upload(name: "#{name}.txt", content_type: "text/plain", body: "abc")
    end

    expect {
      result = described_class.new(user: user, repository: repository).call(
        title: "Too much text",
        description: "Inspect it.",
        attachments: attachments
      )

      expect(result).not_to be_success
      expect(result.error).to eq("Attachments must total 20 MB or less.")
    }.not_to change(ChatSession, :count)
  end
end
