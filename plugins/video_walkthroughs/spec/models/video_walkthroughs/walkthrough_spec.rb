require "rails_helper"

RSpec.describe VideoWalkthroughs::Walkthrough do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def build_walkthrough(attach: true, **attrs)
    described_class.new({
      chat_session: chat_session,
      user: user,
      content_type: "video/webm",
      byte_size: 1024,
      duration_seconds: 90
    }.merge(attrs)).tap do |walkthrough|
      if attach
        walkthrough.file.attach(io: StringIO.new("x"), filename: "w.webm", content_type: "video/webm")
      end
    end
  end

  it "accepts a valid webm walkthrough" do
    walkthrough = build_walkthrough

    expect(walkthrough).to be_valid
    walkthrough.save!
    expect(walkthrough.reload.file).to be_attached
    expect(walkthrough.state).to eq("uploaded")
  end

  it "allows a nil duration (drag-ins where the browser could not read it)" do
    expect(build_walkthrough(duration_seconds: nil)).to be_valid
  end

  it "rejects non-video content types" do
    walkthrough = build_walkthrough(content_type: "application/pdf")

    expect(walkthrough).not_to be_valid
    expect(walkthrough.errors[:content_type]).to include("must be a webm, mp4, or QuickTime video")
  end

  it "rejects files over 500 MB" do
    walkthrough = build_walkthrough(byte_size: described_class::MAX_FILE_SIZE + 1)

    expect(walkthrough).not_to be_valid
    expect(walkthrough.errors[:byte_size]).to be_present
  end

  it "rejects videos longer than 15 minutes" do
    walkthrough = build_walkthrough(duration_seconds: described_class::MAX_DURATION_SECONDS + 1)

    expect(walkthrough).not_to be_valid
    expect(walkthrough.errors[:duration_seconds]).to be_present
  end

  it "requires an attached file" do
    walkthrough = build_walkthrough(attach: false)

    expect(walkthrough).not_to be_valid
    expect(walkthrough.errors[:file]).to include("must be attached")
  end

  # The file_attached validation is `on: :create` only: the prune job purges
  # the blob from settled rows, and a re-delivery retry (analysis already
  # present) doesn't need the video — so a later update on a blob-less row
  # must not be blocked by the attachment requirement.
  it "allows updating a persisted row after its blob has been purged" do
    walkthrough = build_walkthrough(state: "analyzed", analysis: { "summary" => "s" })
    walkthrough.save!
    walkthrough.file.purge
    expect(walkthrough.reload.file).not_to be_attached

    expect { walkthrough.update!(state: "uploaded", error_message: nil) }.not_to raise_error
    expect(walkthrough.reload.state).to eq("uploaded")
  end

  it "rejects states outside the lifecycle" do
    walkthrough = build_walkthrough(state: "bogus")

    expect(walkthrough).not_to be_valid
    expect(walkthrough.errors[:state]).to be_present
  end

  describe "state helpers" do
    it "defaults to uploaded" do
      walkthrough = build_walkthrough

      expect(walkthrough).to be_uploaded
      expect(walkthrough).not_to be_analyzing
      expect(walkthrough).not_to be_analyzed
      expect(walkthrough).not_to be_failed
    end

    it "reflects each lifecycle state" do
      walkthrough = build_walkthrough

      described_class::STATES.each do |state|
        walkthrough.state = state
        expect(walkthrough.public_send("#{state}?")).to be true
        (described_class::STATES - [state]).each do |other|
          expect(walkthrough.public_send("#{other}?")).to be false
        end
      end
    end
  end

  describe "note column" do
    it "persists and reads back the user's note" do
      walkthrough = build_walkthrough(note: "Focus on the flaky Save button")

      expect(walkthrough).to be_valid
      walkthrough.save!
      expect(walkthrough.reload.note).to eq("Focus on the flaky Save button")
    end

    it "allows a nil note" do
      expect(build_walkthrough(note: nil)).to be_valid
    end
  end

  describe "analysis accessors" do
    it "returns empty values when no analysis has been stored" do
      walkthrough = build_walkthrough(analysis: nil)

      expect(walkthrough.analysis_summary).to eq("")
      expect(walkthrough.analysis_issues).to eq([])
      expect(walkthrough.analysis_open_questions).to eq([])
    end

    it "digs summary, issues, and open questions out of a populated analysis" do
      walkthrough = build_walkthrough(
        analysis: {
          "summary" => "The checkout flow mostly works.",
          "issues" => [ { "title" => "Total renders as NaN", "severity" => "high" } ],
          "open_questions" => [ "Is the coupon field intentional?" ]
        }
      )

      expect(walkthrough.analysis_summary).to eq("The checkout flow mostly works.")
      expect(walkthrough.analysis_issues).to eq([ { "title" => "Total renders as NaN", "severity" => "high" } ])
      expect(walkthrough.analysis_open_questions).to eq([ "Is the coupon field intentional?" ])
    end
  end
end
