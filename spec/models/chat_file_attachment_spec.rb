require "rails_helper"

RSpec.describe ChatFileAttachment do
  it "purges its Active Storage blob when the attachment record is destroyed" do
    chat = ChatSession.create!(user: Factories.user)
    attachment = chat.chat_file_attachments.build(name: "notes.txt", mime_type: "text/plain", byte_size: 5, checksum: "pending")
    attachment.file.attach(io: StringIO.new("hello"), filename: "notes.txt", content_type: "text/plain")
    attachment.save!
    blob_id = attachment.file.blob.id

    attachment.destroy!

    expect(ActiveStorage::Blob.where(id: blob_id)).not_to exist
  end
end
