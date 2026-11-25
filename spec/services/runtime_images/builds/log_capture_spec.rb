require "rails_helper"

RSpec.describe RuntimeImages::Builds::LogCapture do
  def capture(*chunks, limit: 10_000)
    log = described_class.new(limit: limit)
    chunks.each { |chunk| log.write(chunk) }
    [ log, log.finish ]
  end

  it "keeps ordinary output" do
    _, text = capture("step 1\nstep 2\n")
    expect(text).to eq("step 1\nstep 2\n")
  end

  it "redacts credentials, headers, URL passwords, and tokens" do
    secrets = %w[ghp_abcdefghijklmnopqrstuvwxyz0123 hunter2 AKIAABCDEFGHIJKLMNOP s3cr3tpass]
    _, text = capture(<<~LOG)
      GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123
      Authorization: Basic dXNlcjpoeHRlcjI=
      curl https://deploy:s3cr3tpass@registry.example.com/v2/
      aws key AKIAABCDEFGHIJKLMNOP
      DB_PASSWORD=hunter2
      Cookie: session=abc
    LOG
    secrets.each { |secret| expect(text).not_to include(secret) }
    expect(text).not_to include("dXNlcjpoeHRlcjI=", "session=abc")
    expect(text).to include("registry.example.com")
  end

  it "does not miss a secret split across chunk boundaries" do
    _, text = capture("pass", "word=hun", "ter2\nnext\n")
    expect(text).not_to include("hunter2")
    expect(text).to include("next")
  end

  it "drops private key blocks entirely" do
    _, text = capture("before\n-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n-----END RSA PRIVATE KEY-----\nafter\n")
    expect(text).to include("before", "after", "private key material omitted")
    expect(text).not_to include("MIIBOg")
  end

  it "strips ANSI and control sequences" do
    _, text = capture("\e[31mred\e[0m\e]0;title\a text\x00\r\n")
    expect(text).to eq("red text\n")
  end

  it "bounds retained bytes, keeps the head, and counts what was dropped" do
    log, text = capture("aaaa\n" * 10, limit: 20)
    expect(text.bytesize).to be <= 20
    expect(text).to start_with("aaaa")
    expect(log.dropped_bytes).to eq(50 - text.bytesize)
    expect(log.seen_bytes).to eq(50)
  end

  it "caps a single enormous unterminated line" do
    log, text = capture("x" * 100_000, limit: 100_000)
    expect(text.bytesize).to be < 20_000
    expect(log.seen_bytes).to eq(100_000)
    expect(log.dropped_bytes).to be > 70_000
  end

  it "survives invalid UTF-8" do
    _, text = capture("bad \xff byte\n".b)
    expect(text).to include("bad")
    expect(text).to be_valid_encoding
  end
end
