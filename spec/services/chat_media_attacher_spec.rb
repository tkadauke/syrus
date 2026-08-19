require "rails_helper"

RSpec.describe ChatMediaAttacher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:job) { Factories.job_record(repository: repository, state: "implemented") }

  def whiteboard_snapshot
    WhiteboardSnapshot.create!(
      chat_session: chat_session,
      name: "My snapshot",
      scene_json: { "elements" => [ { "id" => "abc" } ], "appState" => {} },
      snapshot_kind: "manual",
      element_count: 1
    )
  end

  def chat_image_document
    doc = Document.new(kind: "file", attachable: user, user: user)
    doc.file.attach(io: StringIO.new("pixels"), filename: "photo.png", content_type: "image/png")
    doc.save!
    ChatAttachment.create!(chat_session: chat_session, attachable: doc, suppress_header_broadcast: true)
    doc
  end

  describe "#attach!" do
    it "attaches a pending_snapshot Document for a snapshot:ID ref" do
      snapshot = whiteboard_snapshot

      result = described_class.new(chat_session: chat_session, job: job).attach!([ "snapshot:#{snapshot.id}" ])

      expect(result.attached.size).to eq(1)
      expect(result.skipped).to be_empty
      attachment = job.job_attachments.first
      expect(attachment).to have_attributes(kind: "pending_snapshot", title: "My snapshot", source_url: "snapshot:#{snapshot.id}")
    end

    it "attaches a file Document for a chat_image:ID ref by re-associating the blob" do
      doc = chat_image_document

      result = described_class.new(chat_session: chat_session, job: job).attach!([ "chat_image:#{doc.id}" ])

      expect(result.attached.size).to eq(1)
      attachment = job.job_attachments.first
      expect(attachment).to have_attributes(kind: "file", title: doc.title, source_url: "chat_image:#{doc.id}")
      expect(attachment.file.blob).to eq(doc.file.blob)
    end

    it "skips refs with an invalid format" do
      result = described_class.new(chat_session: chat_session, job: job).attach!([ "bogus-ref" ])

      expect(result.attached).to be_empty
      expect(result.skipped).to eq([ { ref: "bogus-ref", reason: "not found or could not be attached" } ])
      expect(job.job_attachments).to be_empty
    end

    it "skips a snapshot ref that does not resolve" do
      result = described_class.new(chat_session: chat_session, job: job).attach!([ "snapshot:999999" ])

      expect(result.attached).to be_empty
      expect(result.skipped.first).to include(ref: "snapshot:999999")
      expect(job.job_attachments).to be_empty
    end

    it "respects Document::MAX_ATTACHMENTS_PER_JOB and skips refs beyond the cap" do
      stub_const("Document::MAX_ATTACHMENTS_PER_JOB", 1)
      first_snapshot = whiteboard_snapshot
      second_snapshot = whiteboard_snapshot

      result = described_class.new(chat_session: chat_session, job: job).attach!(
        [ "snapshot:#{first_snapshot.id}", "snapshot:#{second_snapshot.id}" ]
      )

      expect(result.attached.size).to eq(1)
      expect(result.skipped).to eq([
        { ref: "snapshot:#{second_snapshot.id}", reason: "attachment limit reached (1 per job)" }
      ])
      expect(job.job_attachments.count).to eq(1)
    end

    it "does not raise when the same ref list is attached across multiple calls up to the cap" do
      stub_const("Document::MAX_ATTACHMENTS_PER_JOB", 2)
      snapshots = Array.new(3) { whiteboard_snapshot }

      result = described_class.new(chat_session: chat_session, job: job).attach!(snapshots.map { |s| "snapshot:#{s.id}" })

      expect(result.attached.size).to eq(2)
      expect(result.any_skipped?).to be(true)
      expect(job.job_attachments.count).to eq(2)
    end
  end
end
