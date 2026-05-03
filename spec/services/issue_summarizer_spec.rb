require "rails_helper"

RSpec.describe IssueSummarizer do
  let(:summarizer) { described_class.new("oat-test") }

  def fake_status(success:)
    instance_double(Process::Status, success?: success)
  end

  describe "#summarize" do
    it "returns trimmed output when the command succeeds" do
      allow(Open3).to receive(:capture2e).and_return(["  A short summary.\n", fake_status(success: true)])
      expect(summarizer.summarize("Fix bug", "The bug is bad.")).to eq("A short summary.")
    end

    it "returns nil when the command exits non-zero" do
      allow(Open3).to receive(:capture2e).and_return(["error output", fake_status(success: false)])
      expect(summarizer.summarize("Fix bug", "The bug is bad.")).to be_nil
    end

    it "returns nil when output is blank" do
      allow(Open3).to receive(:capture2e).and_return(["   \n", fake_status(success: true)])
      expect(summarizer.summarize("Fix bug", "")).to be_nil
    end

    it "returns nil and logs a warning when Open3 raises" do
      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT, "claude not found")
      allow(Rails.logger).to receive(:warn)
      result = summarizer.summarize("Fix bug", "The bug is bad.")
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/IssueSummarizer/)
    end

    it "passes the oauth token in the process environment" do
      captured_env = nil
      allow(Open3).to receive(:capture2e) do |env, *_|
        captured_env = env
        ["summary text", fake_status(success: true)]
      end
      summarizer.summarize("Fix bug", "The bug is bad.")
      expect(captured_env["CLAUDE_CODE_OAUTH_TOKEN"]).to eq("oat-test")
    end

    it "includes the title and body in the prompt passed to claude" do
      captured_args = nil
      allow(Open3).to receive(:capture2e) do |_env, *args, **_kwargs|
        captured_args = args
        ["summary text", fake_status(success: true)]
      end
      summarizer.summarize("My issue title", "My issue body text.")
      prompt_arg = captured_args.last
      expect(prompt_arg).to include("My issue title")
      expect(prompt_arg).to include("My issue body text.")
    end
  end
end
