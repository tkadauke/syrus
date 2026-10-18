require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "bin/test-whisper-stt-image" do
  let(:script) { File.expand_path("../../bin/test-whisper-stt-image", __dir__) }

  it "skips cleanly when the grader worker has no Docker CLI" do
    Dir.mktmpdir do |empty_path|
      stdout, stderr, status = Open3.capture3(
        { "PATH" => empty_path },
        "/bin/bash", script,
        unsetenv_others: true
      )

      expect(status).to be_success, stderr
      expect(stdout).to include("SKIP: Whisper image smoke requires Docker")
    end
  end
end
