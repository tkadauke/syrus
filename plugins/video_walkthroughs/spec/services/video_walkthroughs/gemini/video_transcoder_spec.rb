require "rails_helper"

RSpec.describe VideoWalkthroughs::Gemini::VideoTranscoder do
  # Status double: responds to success? like Process::Status does, so the
  # transcoder's success?(status) helper takes the success? branch. Named
  # under this example group so it doesn't collide with the sibling
  # frame_extractor_spec's top-level Status constant.
  TranscoderStatus = Struct.new(:success) do
    def success?
      success
    end
  end

  def ok_status
    TranscoderStatus.new(true)
  end

  def fail_status
    TranscoderStatus.new(false)
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

  describe ".to_compact_mp4" do
    # A runner that stands in for the real ffmpeg call: the output path is the
    # last element of the cmd array, so we "produce" an mp4 by writing bytes
    # there and reporting success. `-version` (availability probe) is answered
    # separately so available? returns true.
    def producing_runner(mp4_bytes: "mp4-bytes", &captured)
      lambda do |cmd|
        if cmd == %w[ffmpeg -version]
          [ "ffmpeg version 6.0", ok_status ]
        else
          captured&.call(cmd)
          File.binwrite(cmd.last, mp4_bytes)
          [ "", ok_status ]
        end
      end
    end

    it "returns true and produces the mp4 when the runner writes a non-empty file" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        described_class.runner = producing_runner(mp4_bytes: "the-mp4")

        result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: out)

        expect(result).to be true
        expect(File.binread(out)).to eq("the-mp4")
      end
    end

    it "passes an ffmpeg command with libx264, a 720 scale, crf 30, faststart, and the output path" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        captured_cmd = nil
        described_class.runner = producing_runner { |cmd| captured_cmd = cmd }

        described_class.to_compact_mp4(input_path: "/tmp/source.webm", output_path: out)

        expect(captured_cmd.first).to eq("ffmpeg")
        expect(captured_cmd).to include("libx264")
        expect(captured_cmd).to include("-crf", described_class::CRF.to_s)
        expect(captured_cmd).to include("-crf", "30")
        # The scale filter caps height at TARGET_HEIGHT (720).
        expect(captured_cmd).to include(a_string_matching(/scale=.*#{described_class::TARGET_HEIGHT}/))
        expect(captured_cmd).to include(a_string_matching(/scale=.*720/))
        # faststart flag for streamable mp4.
        expect(captured_cmd).to include("+faststart")
        # Input and output paths are present, output is the final arg.
        expect(captured_cmd).to include("/tmp/source.webm")
        expect(captured_cmd.last).to eq(out)
      end
    end

    it "returns false when the runner reports a non-success status" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        described_class.runner = lambda do |cmd|
          if cmd == %w[ffmpeg -version]
            [ "ffmpeg version 6.0", ok_status ]
          else
            # Even if it happens to write output, a failed status → false.
            File.binwrite(cmd.last, "partial")
            [ "encode error", fail_status ]
          end
        end

        result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: out)

        expect(result).to be false
      end
    end

    it "returns false when available? is false (ffmpeg missing), without running the transcode" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        described_class.runner = ->(_cmd) { [ "", fail_status ] } # -version fails → not available

        result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: out)

        expect(result).to be false
        expect(File.exist?(out)).to be false
      end
    end

    it "returns false when the runner succeeds but produces no output file" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        described_class.runner = lambda do |cmd|
          if cmd == %w[ffmpeg -version]
            [ "ffmpeg version 6.0", ok_status ]
          else
            # Success status but no file written → File.exist? is false → false.
            [ "", ok_status ]
          end
        end

        result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: out)

        expect(result).to be false
      end
    end

    it "returns false when the produced output file is empty" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "compact.mp4")
        described_class.runner = producing_runner(mp4_bytes: "")

        result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: out)

        expect(result).to be false
      end
    end

    it "returns false (never raises) when the runner raises during transcode" do
      described_class.runner = lambda do |cmd|
        if cmd == %w[ffmpeg -version]
          [ "ffmpeg version 6.0", ok_status ]
        else
          raise "runner exploded"
        end
      end

      expect {
        @result = described_class.to_compact_mp4(input_path: "/tmp/in.webm", output_path: "/tmp/out.mp4")
      }.not_to raise_error
      expect(@result).to be false
    end
  end
end
