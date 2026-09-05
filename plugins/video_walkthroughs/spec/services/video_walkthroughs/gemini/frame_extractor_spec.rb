require "rails_helper"

RSpec.describe VideoWalkthroughs::Gemini::FrameExtractor do
  # Status double: responds to success? like Process::Status does, so the
  # extractor's `status.respond_to?(:success?) ? ... : ...` branch takes the
  # success? path.
  Status = Struct.new(:success) do
    def success?
      success
    end
  end

  def ok_status
    Status.new(true)
  end

  def fail_status
    Status.new(false)
  end

  # Restore the class-level runner seam after every example that swaps it.
  around do |example|
    original = described_class.runner
    begin
      example.run
    ensure
      described_class.runner = original
    end
  end

  describe ".parse_timestamp" do
    {
      "00:06" => 6,
      "1:16" => 76,
      "01:12" => 72,
      "1:02:03" => 3723,
      "90" => 90,
      "0" => 0,
      "" => nil,
      "   " => nil,
      "garbage" => nil,
      "-5" => nil,
      "1:2:3:4" => nil,
      nil => nil
    }.each do |input, expected|
      it "parses #{input.inspect} → #{expected.inspect}" do
        expect(described_class.parse_timestamp(input)).to eq(expected)
      end
    end
  end

  describe ".available?" do
    it "is true when the runner reports ffmpeg -version success" do
      described_class.runner = ->(cmd) { expect(cmd).to eq(%w[ffmpeg -version]); [ "ffmpeg version 6.0", ok_status ] }

      expect(described_class.available?).to be true
    end

    it "is false when the runner reports a non-success status" do
      described_class.runner = ->(_cmd) { [ "not found", fail_status ] }

      expect(described_class.available?).to be false
    end

    it "is false when the runner raises Errno::ENOENT (ffmpeg absent)" do
      described_class.runner = ->(_cmd) { raise Errno::ENOENT, "No such file - ffmpeg" }

      expect(described_class.available?).to be false
    end
  end

  describe ".extract" do
    # A runner that stands in for the real ffmpeg call: the out path is the
    # last element of the cmd array, so we "produce" a frame by writing JPEG
    # bytes there and reporting success. `-version` (availability probe) is
    # answered separately so available? returns true.
    def writing_runner(jpeg_bytes: "jpeg-bytes")
      lambda do |cmd|
        if cmd == %w[ffmpeg -version]
          [ "ffmpeg version 6.0", ok_status ]
        else
          File.binwrite(cmd.last, jpeg_bytes)
          [ "", ok_status ]
        end
      end
    end

    it "returns [] when ffmpeg is unavailable" do
      described_class.runner = ->(_cmd) { [ "", fail_status ] } # -version fails → not available

      frames = described_class.extract(
        video_path: "/tmp/video.webm",
        timestamps: [ { seconds: 5, label: "Issue" } ]
      )

      expect(frames).to eq([])
    end

    it "returns [] for blank timestamps" do
      described_class.runner = writing_runner

      expect(described_class.extract(video_path: "/tmp/video.webm", timestamps: [])).to eq([])
      expect(described_class.extract(video_path: "/tmp/video.webm", timestamps: nil)).to eq([])
    end

    it "extracts a frame per timestamp with the right seconds and label" do
      described_class.runner = writing_runner(jpeg_bytes: "the-jpeg")

      frames = described_class.extract(
        video_path: "/tmp/video.webm",
        timestamps: [
          { seconds: 12, label: "Save button" },
          { seconds: 90, label: "NaN total" }
        ]
      )

      expect(frames.size).to eq(2)
      expect(frames.map(&:seconds)).to eq([ 12, 90 ])
      expect(frames.map(&:label)).to eq([ "Save button", "NaN total" ])
      expect(frames.map(&:jpeg)).to all(eq("the-jpeg"))
      expect(frames).to all(be_a(VideoWalkthroughs::Gemini::FrameExtractor::Frame))
    end

    it "skips negative and nil timestamps but keeps the valid ones" do
      described_class.runner = writing_runner

      frames = described_class.extract(
        video_path: "/tmp/video.webm",
        timestamps: [
          { seconds: -5, label: "before start" },
          { seconds: nil, label: "unparseable" },
          { seconds: 20, label: "real issue" }
        ]
      )

      expect(frames.map(&:seconds)).to eq([ 20 ])
      expect(frames.map(&:label)).to eq([ "real issue" ])
    end

    it "skips frames the runner fails to produce (no jpeg written)" do
      described_class.runner = lambda do |cmd|
        if cmd == %w[ffmpeg -version]
          [ "", ok_status ]
        else
          # Report success but write nothing → File.exist?(out) is false → skip.
          [ "", ok_status ]
        end
      end

      frames = described_class.extract(
        video_path: "/tmp/video.webm",
        timestamps: [ { seconds: 10, label: "vanishes" } ]
      )

      expect(frames).to eq([])
    end

    it "caps output at MAX_FRAMES even when more timestamps are supplied" do
      described_class.runner = writing_runner
      timestamps = (1..(described_class::MAX_FRAMES + 5)).map { |n| { seconds: n, label: "issue #{n}" } }

      frames = described_class.extract(video_path: "/tmp/video.webm", timestamps: timestamps)

      expect(frames.size).to eq(described_class::MAX_FRAMES)
      # First MAX_FRAMES timestamps, in order.
      expect(frames.map(&:seconds)).to eq((1..described_class::MAX_FRAMES).to_a)
    end
  end

  # ffmpeg isn't in the test image (frames can't actually be rendered), so the
  # "higher resolution" contract is asserted at the COMMAND level: the ffmpeg
  # scale filter width and JPEG quality flag are what determine the frame's
  # dimensions and fidelity.
  describe "extraction resolution" do
    # Records the ffmpeg commands and produces a frame for each so extract
    # returns; answers the -version probe so available? is true.
    def recording_runner(cmds)
      lambda do |cmd|
        if cmd == %w[ffmpeg -version]
          [ "ffmpeg version 6.0", ok_status ]
        else
          cmds << cmd
          File.binwrite(cmd.last, "jpeg-bytes")
          [ "", ok_status ]
        end
      end
    end

    def scale_for(cmd)
      cmd[cmd.index("-vf") + 1]
    end

    def quality_for(cmd)
      cmd[cmd.index("-q:v") + 1]
    end

    it "defaults to the compact 720p-class width and standard JPEG quality" do
      cmds = []
      described_class.runner = recording_runner(cmds)

      described_class.extract(video_path: "/tmp/v.webm", timestamps: [ { seconds: 5, label: "x" } ])

      expect(scale_for(cmds.first)).to eq("scale=#{described_class::SCALE_WIDTH}:-1")
      expect(scale_for(cmds.first)).to eq("scale=1280:-1")
      expect(quality_for(cmds.first)).to eq(described_class::JPEG_QUALITY.to_s)
    end

    it "extracts a flagged (high-res) entry at the wider OCR-grade width and top quality" do
      cmds = []
      described_class.runner = recording_runner(cmds)

      described_class.extract(
        video_path: "/tmp/v.webm",
        timestamps: [ {
          seconds: 5, label: "unreadable code",
          scale_width: described_class::HIGH_SCALE_WIDTH,
          jpeg_quality: described_class::HIGH_JPEG_QUALITY
        } ]
      )

      expect(scale_for(cmds.first)).to eq("scale=1920:-1")
      expect(quality_for(cmds.first)).to eq("2")
      # The higher width really is greater than the compact default.
      expect(described_class::HIGH_SCALE_WIDTH).to be > described_class::SCALE_WIDTH
    end

    it "honors per-entry resolution overrides independently within one call" do
      cmds = []
      described_class.runner = recording_runner(cmds)

      described_class.extract(
        video_path: "/tmp/v.webm",
        timestamps: [
          { seconds: 5, label: "plain" },
          { seconds: 9, label: "flagged", scale_width: described_class::HIGH_SCALE_WIDTH, jpeg_quality: described_class::HIGH_JPEG_QUALITY }
        ]
      )

      expect(scale_for(cmds[0])).to eq("scale=1280:-1")
      expect(scale_for(cmds[1])).to eq("scale=1920:-1")
    end

    it "applies a call-level scale_width/jpeg_quality to entries without their own override" do
      cmds = []
      described_class.runner = recording_runner(cmds)

      described_class.extract(
        video_path: "/tmp/v.webm",
        timestamps: [ { seconds: 5, label: "x" } ],
        scale_width: 1600, jpeg_quality: 3
      )

      expect(scale_for(cmds.first)).to eq("scale=1600:-1")
      expect(quality_for(cmds.first)).to eq("3")
    end
  end
end
