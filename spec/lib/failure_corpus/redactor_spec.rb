require "rails_helper"
require Rails.root.join("lib/failure_corpus/redactor").to_s
require Rails.root.join("lib/failure_corpus/exporter").to_s

RSpec.describe FailureCorpus::Redactor do
  after { described_class.identifiers = [] }

  describe ".scrub" do
    it "redacts the credential in an authenticated git URL but keeps the identifier the classifier reads" do
      text = "git push https://x-access-token:ghs_abcdefghijklmnopqrstuvwxyz0123@github.com/acme/widgets.git HEAD exited 1"

      scrubbed = described_class.scrub(text)

      expect(scrubbed).to include("https://x-access-token:[REDACTED]@github.com/example/repo.git")
      expect(scrubbed).not_to include("ghs_abcdefghijklmnopqrstuvwxyz0123")
    end

    it "redacts credentials in any URL scheme and token-as-user URLs" do
      text = "mysql2://syrus:hunter2secret@db:3306/x and https://ghp_0123456789abcdefghij@github.com/acme/widgets"

      scrubbed = described_class.scrub(text)

      expect(scrubbed).to include("mysql2://syrus:[REDACTED]@db")
      expect(scrubbed).to include("https://[REDACTED]@github.com/")
      expect(scrubbed).not_to include("hunter2secret")
      expect(scrubbed).not_to include("ghp_0123456789abcdefghij")
    end

    it "redacts bare provider and GitHub tokens, bearer headers and private keys" do
      text = <<~TEXT
        token ghp_abcdefghijklmnopqrstuvwxyz012345
        key sk-ant-api03-abcdefghijklmnopqrstuvwxyz
        openai sk-proj-abcdefghijklmnopqrstuvwxyz123456
        Authorization: Bearer abc.def.ghijklmnopqrstuvwxyz
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
      TEXT

      scrubbed = described_class.scrub(text)

      %w[ghp_abcdefghijklmnopqrstuvwxyz012345 sk-ant-api03-abcdefghij sk-proj-abcdefghij
         abc.def.ghijklmnopqrstuvwxyz eyJhbGciOiJIUzI1NiJ9 b3BlbnNzaC1rZXktdjEAAAAA].each do |secret|
        expect(scrubbed).not_to include(secret)
      end
      expect(scrubbed).to include("Bearer [REDACTED]", "[REDACTED PRIVATE KEY]")
    end

    it "redacts sensitive assignments but keeps failure phrasing the classifier matches" do
      text = "OPENAI_API_KEY=abc123def456 password: \"s3cret!\" api_key=invalid token: expired"

      scrubbed = described_class.scrub(text)

      expect(scrubbed).to include("OPENAI_API_KEY=[REDACTED]", "password: \"[REDACTED]\"")
      expect(scrubbed).to include("api_key=invalid", "token: expired")
      expect(scrubbed).not_to include("abc123def456", "s3cret!")
    end

    it "anonymizes internal hosts, home directories, e-mail addresses and instance names" do
      described_class.identifiers = %w[acme-corp jdoe Syrus]

      scrubbed = described_class.scrub(
        "connect syrus.internal.example-lab.internal from /Users/jdoe/code as jdoe@acme.io " \
        "in acme-corp/widgets via mcp__syrus-mcp-sidecar"
      )

      expect(scrubbed).to include("host.example.test", "/Users/user/code", "user@example.test", "example/widgets")
      expect(scrubbed).not_to include("jdoe", "acme-corp")
      # Identifiers under three characters are ignored; product names are
      # left to the exporter's preserved-word list.
      expect(scrubbed).to include("mcp__example-mcp-sidecar")
    end

    it "drops NUL bytes and invalid UTF-8" do
      expect(described_class.scrub("a\u0000b\xFFc".dup.force_encoding("BINARY"))).to eq("abc")
    end
  end

  describe ".truncate" do
    it "keeps both ends of a long text" do
      text = "HEAD-#{'x' * 10_000}-TAIL"

      truncated = described_class.truncate(text, 1_000)

      expect(truncated).to start_with("HEAD-")
      expect(truncated).to end_with("-TAIL")
      expect(truncated).to include("chars elided")
      expect(truncated.length).to be < 1_100
    end
  end

  describe ".call" do
    it "scrubs strings nested in hashes and arrays" do
      value = { "url" => "https://x-access-token:ghs_abcdefghijklmnop@github.com/a/b", "list" => [ "Bearer abcdefghijklmnopq" ], "n" => 3 }

      expect(described_class.call(value)).to eq(
        "url" => "https://x-access-token:[REDACTED]@github.com/example/repo",
        "list" => [ "Bearer [REDACTED]" ],
        "n" => 3
      )
    end
  end
end

RSpec.describe FailureCorpus::Exporter do
  after { FailureCorpus::Redactor.identifiers = [] }

  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  def fail_run!(message:, logs: [])
    run.update_columns(state: "failed", finished_at: Time.current)
    logs.each_with_index do |chunk, index|
      JobLog.create!(run: run, sequence: 1_000 + index, chunk: chunk, kind: "system", created_at: 2.minutes.ago)
    end
    run.create_run_diagnostic!(error_class: "GitRunner::GitError", error_message: message)
    RunFailureClassifier.persist!(run.reload)
    run.reload
  end

  it "exports sanitized cases whose sanitized inputs keep the classifier's verdict" do
    secret = "ghs_abcdefghijklmnopqrstuvwxyz0123"
    fail_run!(
      message: "git ls-remote https://x-access-token:#{secret}@github.com/acme/widgets.git exited 128\n" \
               "fatal: unable to access: Could not resolve host: github.com",
      logs: [ "Authorization: Bearer #{secret}" ]
    )

    cases = ActiveRecord::Base.while_preventing_writes { described_class.call(days: 1) }

    expect(cases.size).to eq(1)
    kase = cases.first
    expect(JSON.generate(kase)).not_to include(secret)
    expect(kase.dig("diagnostic", "error_message")).to include("x-access-token:[REDACTED]@github.com")
    expect(kase["recorded"]).to include("classification" => "git_transport_transient", "retryable" => true, "source" => "classifier")
    expect(kase["export_verdict"]).to eq("classification" => "git_transport_transient", "retryable" => true)
    expect(kase["logs"].last).to eq("kind" => "system", "chunk" => "Authorization: Bearer [REDACTED]")
  end

  it "drops a case whose recorded evidence no longer survives" do
    fail_run!(message: "fatal: unable to access: Could not resolve host: github.com")
    classification = run.run_failure_classification
    classification.update_columns(classifier_inputs: classification.classifier_inputs.merge("spawned_process_outcomes" => [ "timed_out" ]).to_json)

    exporter = described_class.new(days: 1)
    cases = ActiveRecord::Base.while_preventing_writes { exporter.call }

    expect(cases).to be_empty
    expect(exporter.stats).to include("dropped_evidence_spawned_process_outcomes" => 1)
  end
end
