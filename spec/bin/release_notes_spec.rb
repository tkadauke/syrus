# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/release-notes" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/release-notes") }

  around do |example|
    Dir.mktmpdir("release-notes") do |dir|
      @dir = dir
      @bin_dir = File.join(dir, "bin")
      @curl_args = File.join(dir, "curl-args.json")
      @curl_stdin = File.join(dir, "curl-stdin")
      @curl_headers = File.join(dir, "curl-headers")
      FileUtils.mkdir_p(@bin_dir)
      initialize_repository
      write_curl_stub
      example.run
    end
  end

  def git!(*args)
    _stdout, stderr, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  def initialize_repository
    git!("init", "-q", "-b", "main")
    git!("config", "user.name", "Release Notes Spec")
    git!("config", "user.email", "release-notes@example.test")
    File.write(File.join(@dir, "README.md"), "first release\n")
    git!("add", "README.md")
    git!("commit", "-q", "-m", "Initial release")
    git!("remote", "add", "origin", ".")
  end

  def write_curl_stub
    stub = File.join(@bin_dir, "curl")
    File.write(stub, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.write(ENV.fetch("CURL_ARGS_FILE"), JSON.generate(ARGV))
      File.write(ENV.fetch("CURL_STDIN_FILE"), STDIN.read)
      File.write(ENV.fetch("CURL_HEADERS_FILE"), IO.new(3).read)
      print({ content: [{ type: "text", text: "Generated notes" }] }.to_json)
    RUBY
    File.chmod(0o755, stub)
  end

  def run_release_notes(version)
    Open3.capture3(
      {
        "CLAUDE_API_KEY" => "top-secret-key",
        "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
        "CURL_ARGS_FILE" => @curl_args,
        "CURL_STDIN_FILE" => @curl_stdin,
        "CURL_HEADERS_FILE" => @curl_headers
      },
      script,
      version,
      "--stdout",
      chdir: @dir
    )
  end

  it "generates a first release with an empty diff stat" do
    stdout, stderr, status = run_release_notes("1.0.0")

    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to eq("Generated notes\n")
    request_body = JSON.parse(File.read(@curl_stdin))
    expect(request_body.dig("messages", 0, "content")).to include("Previous stable release: none")
    expect(request_body.dig("messages", 0, "content")).not_to include("Diff stat:")
  end

  it "uses the v-prefixed tag when VERSION is unprefixed" do
    git!("tag", "v1.0.0")
    File.write(File.join(@dir, "README.md"), "unreleased change\n")
    git!("add", "README.md")
    git!("commit", "-q", "-m", "Unreleased change")

    _stdout, stderr, status = run_release_notes("1.0.0")

    expect(status).to be_success, stderr
    request_body = JSON.parse(File.read(@curl_stdin))
    prompt = request_body.dig("messages", 0, "content")
    expect(prompt).to include("Target ref: v1.0.0")
    expect(prompt).to include("Initial release")
    expect(prompt).not_to include("Unreleased change")
  end

  it "keeps the API key and request body out of curl argv" do
    _stdout, stderr, status = run_release_notes("1.0.0")

    expect(status).to be_success, stderr
    curl_args = JSON.parse(File.read(@curl_args))
    expect(curl_args).to include("-H", "@/dev/fd/3", "--data-binary", "@-")
    expect(curl_args.join(" ")).not_to include("top-secret-key")
    expect(curl_args.join(" ")).not_to include("Initial release")
    expect(File.read(@curl_headers)).to include("x-api-key: top-secret-key")
    expect(JSON.parse(File.read(@curl_stdin)).dig("messages", 0, "content")).to include("Initial release")
  end
end
