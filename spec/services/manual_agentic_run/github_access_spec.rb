require "rails_helper"
require "net/http"

RSpec.describe ManualAgenticRun::GithubAccess do
  let(:user) { Factories.user }
  let(:installation) { Factories.installation(user: user, account_login: "acme") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", installation: installation, github_repository_id: 123) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "manual_agentic_run", agent_provider: "codex") }
  let(:step) { Step.create!(workflow: workflow, kind: "manual_agentic_run", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: "codex") }
  let(:access) { described_class.new(run) }

  # The wrapped "real" gh/git must exist on every host: /bin/true is absent on
  # macOS (it lives at /usr/bin/true there), so a hard-coded path made the
  # wrapper exit 127. A stub executable created here is host-independent.
  let(:real_command_dir) { Dir.mktmpdir("github-access-real-command") }
  let(:real_command) do
    File.join(real_command_dir, "true").tap do |path|
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, path)
    end
  end

  before do
    workflow.set_artifact!("manual_agentic_run_github_access", true)
    allow_any_instance_of(Installation).to receive(:scoped_token).and_return(token: "ghs_top_secret", expires_at: 30.minutes.from_now)
    allow(access).to receive(:real_command).with("gh").and_return(real_command)
    allow(access).to receive(:real_command).with("git").and_return(real_command)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Rails.root)
  end

  after do
    described_class.cleanup(run)
    FileUtils.rm_rf(real_command_dir)
  end

  it "does not place the credential in the ambient agent environment or audit evidence" do
    env = access.environment
    expect(env).not_to have_key("GH_TOKEN")
    wrapper_dir = env.fetch("PATH").split(":").first
    expect(Dir.children(wrapper_dir)).to contain_exactly("broker-ca.pem", "broker.sock", "gh", "git")
    expect(Dir.glob("#{wrapper_dir}/**/*").select { |path| File.file?(path) }.map { |path| File.binread(path) }.join).not_to include("ghs_top_secret")
    expect(env.to_json).not_to include("credential", "audit.jsonl", "ghs_top_secret")

    _out, err, status = Open3.capture3(env, File.join(wrapper_dir, "gh"), "api", "/repos/acme/widgets")
    expect(status).to be_success
    expect(err).not_to include("ghs_top_secret")
    expect(access.collect_audit!.to_json).not_to include("ghs_top_secret")
  end

  it "keeps the real credential out of provider subprocess environments" do
    Dir.mktmpdir do |dir|
      proxy = described_class::CredentialProxy.new(dir:, token: "ghs_top_secret", repository: repository.slug, destructive: false).start
      environments = [ proxy.gh_environment, proxy.git_environment ]

      expect(environments.to_json).not_to include("ghs_top_secret")
      expect(proxy.gh_environment.fetch("GH_ENTERPRISE_TOKEN")).not_to eq("ghs_top_secret")
      expect(proxy.git_environment.values).to include("https://github.com/", "git@github.com:")
    ensure
      proxy&.stop
    end
  end

  it "enforces exact repository and destructive semantics at the credential proxy" do
    Dir.mktmpdir do |dir|
      proxy = described_class::CredentialProxy.new(dir:, token: "ghs_top_secret", repository: repository.slug, destructive: false).start

      expect { proxy.send(:upstream_for, "/api/v3/repos/acme/widgets-evil/issues") }
        .to raise_error(/restricted to acme\/widgets/)
      expect(proxy.send(:destructive_request?, "PATCH", "/repos/acme/widgets/pulls/9", '{"state":"closed"}')).to be(true)
      expect(proxy.send(:destructive_request?, "PATCH", "/repos/acme/widgets", '{"archived":true}')).to be(true)
      expect(proxy.send(:destructive_request?, "POST", "/repos/acme/widgets/issues/9/lock", "")).to be(true)
      expect(proxy.send(:destructive_request?, "PATCH", "/repos/acme/widgets/pulls/9?notify=false", '{"state":"closed"}')).to be(true)
      expect(proxy.send(:destructive_request?, "PATCH", "/repos/acme/widgets?audit=repair", '{"archived":true}')).to be(true)
      expect(proxy.send(:destructive_request?, "POST", "/repos/acme/widgets/issues/9/lock?reason=repair", "")).to be(true)
      deletion = "0" * 4 + ("a" * 40) + " " + ("0" * 40) + " refs/heads/repair\0 report-status\n"
      expect(proxy.send(:destructive_request?, "POST", "/acme/widgets.git/git-receive-pack", deletion)).to be(true)
    ensure
      proxy&.stop
    end
  end

  it "forwards the authenticated REST request shape used by gh api" do
    Dir.mktmpdir do |dir|
      proxy = described_class::CredentialProxy.new(dir:, token: "ghs_top_secret", repository: repository.slug, destructive: false).start
      upstream = Struct.new(:status, :body, :headers).new(200, '{"id":123}', { "content-type" => "application/json" })
      allow(Faraday).to receive(:get).and_return(upstream)
      env = proxy.gh_environment
      uri = URI("https://#{env.fetch('GH_HOST')}/api/v3/repos/acme/widgets")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "token #{env.fetch('GH_ENTERPRISE_TOKEN')}"
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.ca_file = env.fetch("SSL_CERT_FILE")

      response = VCR.turned_off { http.request(request) }

      expect(response).to have_attributes(code: "200", body: '{"id":123}')
      expect(Faraday).to have_received(:get).with("https://api.github.com/repos/acme/widgets", "")
    ensure
      proxy&.stop
    end
  end

  it "rejects cross-repository access before invoking GitHub" do
    env = access.environment
    _out, err, status = Open3.capture3(env, File.join(env.fetch("PATH").split(":").first, "gh"), "api", "/repos/other/repo")

    expect(status.exitstatus).to eq(77)
    expect(err).to include("restricted to acme/widgets")
  end

  it "rejects commands launched outside the workflow workspace" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "gh")
    Dir.mktmpdir do |outside|
      _out, err, status = Open3.capture3(env, wrapper, "api", "/repos/acme/widgets", chdir: outside)

      expect(status.exitstatus).to eq(77)
      expect(err).to include("restricted to the workflow workspace")
    end
  end

  it "rejects destructive commands without separate authority" do
    env = access.environment
    _out, err, status = Open3.capture3(env, File.join(env.fetch("PATH").split(":").first, "gh"), "api", "/repos/acme/widgets/issues/9", "-X", "PUT")

    expect(status.exitstatus).to eq(78)
    expect(err).to include("separately confirmed destructive authority")
  end

  it "rejects high-level GraphQL-backed gh commands explicitly" do
    env = access.environment
    _out, err, status = Open3.capture3(env, File.join(env.fetch("PATH").split(":").first, "gh"), "pr", "view", "9")

    expect(status.exitstatus).to eq(79)
    expect(err).to include("high-level gh commands are unavailable", "only gh api")
  end

  it "rejects the long gh api destructive method without separate authority" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "gh")
    _out, err, status = Open3.capture3(env, wrapper, "api", "/repos/acme/widgets/issues/9", "--method", "DELETE")

    expect(status.exitstatus).to eq(78)
    expect(err).to include("separately confirmed destructive authority")
  end

  it "rejects the equals form of a destructive gh api method" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "gh")
    _out, err, status = Open3.capture3(env, wrapper, "api", "/repos/acme/widgets/issues/9", "--method=DELETE")

    expect(status.exitstatus).to eq(78)
    expect(err).to include("separately confirmed destructive authority")
  end

  it "rejects destructive Git ref operations without separate authority" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "git")

    [ [ "push", "origin", "--delete", "repair" ], [ "push", "origin", ":repair" ],
      [ "push", "--force", "origin", "repair" ], [ "push", "-f", "origin", "repair" ],
      [ "push", "-d", "origin", "repair" ], [ "push", "--force-with-lease=repair", "origin", "repair" ],
      [ "push", "--mirror", "origin" ], [ "push", "--prune", "origin" ],
      [ "push", "origin", "+repair:repair" ] ].each do |args|
      _out, err, status = Open3.capture3(env, wrapper, *args)
      expect(status.exitstatus).to eq(78), args.join(" ")
      expect(err).to include("separately confirmed destructive authority")
    end
  end

  it "blocks token-printing commands and organization API access" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "gh")

    _out, auth_err, auth_status = Open3.capture3(env, wrapper, "auth", "token")
    _out, api_err, api_status = Open3.capture3(env, wrapper, "api", "/orgs/acme")

    expect(auth_status.exitstatus).to eq(79)
    expect(auth_err).to include("unavailable")
    expect(api_status.exitstatus).to eq(77)
    expect(api_err).to include("restricted to repos/acme/widgets")
  end

  it "rejects an expired credential before launching the agent" do
    allow_any_instance_of(Installation).to receive(:scoped_token).and_return(token: "ghs_expired", expires_at: 1.second.ago)

    expect { access.environment }.to raise_error(ArgumentError, /already expired/)
  end

  it "rejects a credential that expires while the agent is running" do
    env = access.environment
    wrapper = File.join(env.fetch("PATH").split(":").first, "gh")

    travel 31.minutes do
      _out, err, status = Open3.capture3(env, wrapper, "pr", "view")
      expect(status.exitstatus).to eq(79)
      expect(err).to include("credential expired")
    end
  end
end
