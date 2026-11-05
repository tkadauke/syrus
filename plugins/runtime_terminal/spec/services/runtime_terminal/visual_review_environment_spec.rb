require "rails_helper"

RSpec.describe RuntimeTerminal::VisualReviewEnvironment do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, user: user) }
  let(:run) { job.runs.last }
  let(:workspace) { Pathname.new(Dir.mktmpdir("visual-review-env")) }
  let(:runtime_session) do
    RuntimeSession.create!(
      repository: repository, job: job, workflow: run.workflow, run: run,
      workspace_ref: workspace.to_s, provider_key: "cli_tui", display_name: "Terminal",
      state: "starting", metadata: { "visual_review_target" => { "environment" => environment } }
    )
  end
  let(:environment) { { "static" => { "APP_MODE" => "review" } } }

  after { FileUtils.remove_entry(workspace) if workspace.exist? }

  it "returns static variables without executing a provider command" do
    expect(described_class.new(runtime_session).call).to eq("APP_MODE" => "review")
  end

  it "returns no repository variables when the target has no environment block" do
    runtime_session.update!(metadata: { "visual_review_target" => {} })
    expect(described_class.new(runtime_session).call).to eq({})
  end

  it "sends only declared inputs and filters generated output through allow_output" do
    script = write_script(<<~'RUBY')
      require "json"
      input = JSON.parse($stdin.read).fetch("inputs")
      abort unless input.keys == ["run_api_endpoint"]
      puts "APP_URL=#{input.fetch('run_api_endpoint')}"
      puts "UNDECLARED_SECRET=drop-me"
    RUBY
    environment["command"] = {
      "argv" => [ script ], "inputs" => [ "run_api_endpoint" ], "allow_output" => [ "APP_URL" ]
    }
    previous_host = ENV["SYRUS_APP_HOST"]
    ENV["SYRUS_APP_HOST"] = "https://syrus.example.test"
    begin
      expect(described_class.new(runtime_session).call).to eq(
        "APP_MODE" => "review", "APP_URL" => "https://syrus.example.test"
      )
      expect(runtime_session.reload.metadata.to_json).not_to include("https://syrus.example.test", "drop-me")
    ensure
      ENV["SYRUS_APP_HOST"] = previous_host
    end
  end

  it "rejects forbidden, duplicate, malformed, failed, and oversized generated output without values in diagnostics" do
    cases = {
      "puts 'PATH=/tmp/attacker-bin'" => /key PATH is forbidden/,
      "puts \"APP_URL=one\\nAPP_URL=two\"" => /duplicate key APP_URL/,
      "puts 'malformed'" => /malformed record/,
      "warn 'stderr-secret'; exit 7" => /status 7; stderr: redacted \(14 bytes\)/,
      "puts 'APP_URL=' + ('x' * 70000)" => /stdout exceeded/,
      "$stderr.write('x' * 9000)" => /stderr exceeded/,
      "$stdout.write(\"APP_URL=\\xFF\".b)" => /stdout is not valid UTF-8/
    }
    cases.each do |body, message|
      environment["command"] = { "argv" => [ write_script(body) ], "inputs" => [], "allow_output" => [ "APP_URL" ] }
      runtime_session.update!(metadata: { "visual_review_target" => { "environment" => environment } })
      expect { described_class.new(runtime_session).call }.to raise_error(described_class::Error, message) do |error|
        expect(error.message).not_to include("stderr-secret", "/tmp/attacker-bin")
      end
    end
  end

  it "rejects duplicate static and generated keys deterministically" do
    environment["command"] = {
      "argv" => [ write_script("puts 'APP_MODE=generated'") ], "inputs" => [], "allow_output" => [ "APP_MODE" ]
    }
    expect { described_class.new(runtime_session).call }
      .to raise_error(described_class::Error, /APP_MODE is declared by both static and generated/)
  end

  it "fails unknown inputs before running the repository executable" do
    marker = workspace.join("ran")
    environment["command"] = {
      "argv" => [ write_script("File.write(#{marker.to_s.inspect}, 'yes')") ],
      "inputs" => [ "unknown_secret" ], "allow_output" => []
    }
    expect { described_class.new(runtime_session).call }.to raise_error(described_class::Error, /unknown or unauthorized/)
    expect(marker).not_to exist
  end

  it "fails unavailable credentials and timeouts without running or leaking input values" do
    run.update!(state: "failed")
    environment["command"] = {
      "argv" => [ write_script("puts 'APP_URL=should-not-run'") ],
      "inputs" => [ "run_api_credential" ], "allow_output" => [ "APP_URL" ]
    }
    expect { described_class.new(runtime_session).call }
      .to raise_error(described_class::Error, /unavailable for an inactive Run/)

    run.update!(state: "running")
    runtime_session.update!(metadata: {
      "visual_review_target" => { "environment" => {
        "static" => {}, "command" => {
          "argv" => [ write_script("sleep 2") ], "inputs" => [], "allow_output" => []
        }
      } }
    })
    stub_const("RuntimeTerminal::VisualReviewEnvironment::TIMEOUT", 0.01.seconds)
    expect { described_class.new(runtime_session).call }
      .to raise_error(described_class::Error, /timed out/)
  end

  it "keeps the repository adapter limited to its two declared generic inputs and outputs" do
    input = JSON.generate("inputs" => {
      "run_api_endpoint" => "https://syrus.example.test",
      "run_api_credential" => "signed-value"
    })
    output, status = Open3.capture2(Rails.root.join("bin/visual-review-env").to_s, stdin_data: input)
    expect(status).to be_success
    expect(output.lines(chomp: true)).to eq([
      "SYRUS_CLI_URL=https://syrus.example.test",
      "SYRUS_CLI_INVOCATION_CONTEXT=signed-value"
    ])
  end

  def write_script(body)
    path = workspace.join("provider-#{SecureRandom.hex(4)}")
    path.write("#!/usr/bin/env ruby\n#{body}\n")
    path.chmod(0o700)
    path.to_s
  end
end
