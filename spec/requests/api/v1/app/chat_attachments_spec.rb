require "rails_helper"

RSpec.describe "API: chat attachments", :ci_only, type: :request do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  it "uploads an authorized file and securely downloads it" do
    sign_in_as(user)
    file = Rack::Test::UploadedFile.new(StringIO.new("hello"), "text/plain", original_filename: "notes.txt")

    post "/api/v1/app/chats/#{chat.id}/attachments", params: { file: file }

    expect(response).to have_http_status(:created)
    payload = JSON.parse(response.body)
    expect(payload).to include("name" => "notes.txt", "mime_type" => "text/plain", "size" => 5)

    get payload.fetch("url")
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("hello")
    expect(response.headers["Content-Disposition"]).to include("notes.txt")
    expect(response.headers["Cache-Control"]).to include("immutable")
  end

  it "downloads a legacy inline message attachment without exposing it in JSON" do
    sign_in_as(user)
    message = chat.messages.create!(role: "user", sender_user: user, content: {
      "text" => "Legacy", "attachments" => [ { "name" => "notes.txt", "mime_type" => "text/plain", "data" => Base64.strict_encode64("hello") } ]
    })

    get "/api/v1/app/chats/#{chat.id}/messages/#{message.id}/attachments/0"

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("hello")
    expect(response.headers["Cache-Control"]).to include("immutable")
  end

  it "does not expose another user's attachment" do
    sign_in_as(Factories.user)

    get "/api/v1/app/chats/#{chat.id}/attachments/1/file"

    expect(response).to have_http_status(:not_found)
  end

  it "rejects uploads from read-only shared-chat recipients" do
    recipient = Factories.user
    ChatShare.create!(chat_session: chat, target: recipient, shared_by_user: user)
    sign_in_as(recipient)
    file = Rack::Test::UploadedFile.new(StringIO.new("hello"), "text/plain", original_filename: "notes.txt")

    post "/api/v1/app/chats/#{chat.id}/attachments", params: { file: file }

    expect(response).to have_http_status(:forbidden)
    expect(chat.chat_file_attachments).to be_empty
  end

  it "enforces the per-file size limit" do
    sign_in_as(user)
    file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (ChatMessageParams::CHAT_ATTACHMENT_MAX_BYTES + 1)),
      "text/plain",
      original_filename: "large.txt"
    )

    post "/api/v1/app/chats/#{chat.id}/attachments", params: { file: file }

    expect(response).to have_http_status(:unprocessable_content)
    expect(chat.chat_file_attachments).to be_empty
  end

  it "does not count attachments from earlier messages against later uploads" do
    sign_in_as(user)
    message = chat.messages.create!(role: "user", sender_user: user, content: { "text" => "Earlier attachment" })
    existing = chat.chat_file_attachments.build(
      attachable: message,
      name: "existing.txt",
      mime_type: "text/plain",
      byte_size: ChatMessageParams::CHAT_ATTACHMENT_TOTAL_MAX_BYTES,
      checksum: "pending"
    )
    existing.file.attach(io: StringIO.new("x"), filename: "existing.txt", content_type: "text/plain")
    existing.save!
    existing.update_column(:byte_size, ChatMessageParams::CHAT_ATTACHMENT_TOTAL_MAX_BYTES)
    file = Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "extra.txt")

    post "/api/v1/app/chats/#{chat.id}/attachments", params: { file: file }

    expect(response).to have_http_status(:created)
    expect(chat.chat_file_attachments.pluck(:name)).to contain_exactly("existing.txt", "extra.txt")
  end

  it "enforces the aggregate size limit when uploaded refs are submitted with a message" do
    sign_in_as(user)
    attachments = 5.times.map do |index|
      chat.chat_file_attachments.create!(
        name: "attachment-#{index}.txt",
        mime_type: "text/plain",
        byte_size: ChatMessageParams::CHAT_ATTACHMENT_MAX_BYTES,
        checksum: "checksum-#{index}"
      )
    end

    post "/api/v1/app/chats/#{chat.id}/message", params: {
      chat_message: { text: "Too many attachments", attachments: attachments.map { |attachment| { id: attachment.id } } }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(chat.messages).to be_empty
  end

  it "rejects invalid UTF-8 text uploads" do
    sign_in_as(user)
    file = Rack::Test::UploadedFile.new(StringIO.new("\xFF".b), "text/plain", original_filename: "invalid.txt")

    post "/api/v1/app/chats/#{chat.id}/attachments", params: { file: file }

    expect(response).to have_http_status(:unprocessable_content)
    expect(chat.chat_file_attachments).to be_empty
  end
end
