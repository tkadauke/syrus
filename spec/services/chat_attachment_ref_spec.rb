require "rails_helper"

RSpec.describe ChatAttachmentRef do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  it "reads a storage-backed attachment and claims it for its message" do
    attachment = chat.chat_file_attachments.build(name: "diagram.png", mime_type: "image/png", byte_size: 3, checksum: "pending")
    attachment.file.attach(io: StringIO.new("png"), filename: "diagram.png", content_type: "image/png")
    attachment.save!
    message = chat.messages.create!(role: "user", content: { "text" => "", "attachments" => [ { "id" => attachment.id } ] }, sender_user: user)

    ref = described_class.for(message).sole

    expect(ref.bytes).to eq("png")
    expect(ref.payload).to include("id" => attachment.id, "url" => "/api/v1/app/chats/#{chat.id}/attachments/#{attachment.id}/file")
    expect(ref.payload).not_to have_key("data")
    expect(attachment.reload.attachable).to eq(message)
  end

  it "ignores attachment metadata that has no stored-file id" do
    message = chat.messages.build(role: "user", content: { "text" => "", "attachments" => [ { "name" => "missing.txt" } ] })

    expect(described_class.for(message)).to be_empty
  end

  it "batch-loads stored attachments for multiple messages" do
    attachments = 2.times.map do |index|
      attachment = chat.chat_file_attachments.build(name: "#{index}.txt", mime_type: "text/plain", byte_size: 1, checksum: "pending")
      attachment.file.attach(io: StringIO.new(index.to_s), filename: "#{index}.txt", content_type: "text/plain")
      attachment.save!
      attachment
    end
    messages = attachments.map do |attachment|
      chat.messages.create!(role: "user", content: { "text" => "", "attachments" => [ { "id" => attachment.id } ] }, sender_user: user)
    end

    refs = nil
    queries = capture_sql do
      described_class.preload(messages)
      refs = messages.flat_map { |message| described_class.for(message) }
      refs.map(&:payload)
    end

    expect(refs.map(&:id)).to eq(attachments.map(&:id))
    expect(refs.map(&:payload)).to all(satisfy { |payload| !payload.key?("data") })
    expect(queries.grep(/FROM ["`]?chat_file_attachments["`]?/i).size).to eq(1)
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:name].to_s.match?(/\ASCHEMA|TRANSACTION\z/)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
