require "rails_helper"

RSpec.describe ManualAgenticRun::GithubAccess do
  let(:user) { Factories.user }
  let(:installation) { Factories.installation(user: user, account_login: "acme") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", installation: installation, github_repository_id: 123) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "manual_agentic_run", agent_provider: "codex") }
  let(:step) { Step.create!(workflow: workflow, kind: "manual_agentic_run", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: "codex") }
  let(:access) { described_class.new(run) }

  before do
    workflow.set_artifact!("manual_agentic_run_github_access", true)
    allow_any_instance_of(Installation).to receive(:scoped_token).and_return(token: "ghs_top_secret", expires_at: 30.minutes.from_now)
    allow(access).to receive(:real_command).with("gh").and_return("/bin/true")
    allow(access).to receive(:real_command).with("git").and_return("/bin/true")
  end

  after { described_class.cleanup(run) }

  it "does not place the credential in the ambient agent environment or audit evidence" do
    env = access.environment
    expect(env).not_to have_key("GH_TOKEN")
    wrapper_dir = env.fetch("PATH").split(":").first
    expect(Dir.children(wrapper_dir)).to contain_exactly("broker-ca.pem", "broker.sock", "gh", "git")
    expect(Dir.glob("#{wrapper_dir}/**/*").select { |path| File.file?(path) }.map { |path| File.binread(path) }.join).not_to include("ghs_top_secret")
    expect(env.to_json).not_to include("credential", "audit.jsonl", "ghs_top_secret")

    _out, err, status = Open3.capture3(env, File.join(wrapper_dir, "gh"), "pr", "view")
    expect(status).to be_success
    expect(err).not_to include("ghs_top_secret")
    expect(access.collect_audit!.to_json).not_to include("ghs_top_secret")
  end

  it "keeps the real credential out of provider subprocess environments" do
    Dir.mktmpdir do |dir|
      proxy = described_class::CredentialProxy.new(dir:, token: "ghs_top_secret", repository: repository.slug, destructive: false).start
      environments = [ proxy.gh_environment, proxy.git_environment ]

      expect(environments.to_json).not_to include("ghs_top_secret")
      expect(proxy.gh_environment).to include("GH_ENTERPRISE_TOKEN" => described_class::CredentialProxy::PLACEHOLDER)
      expect(proxy.git_environment.values).to include("https://github.com/", "git@github.com:")
    ensure
      proxy&.stop
    end
  end

  it "rejects cross-repository access before invoking GitHub" do
    env = access.environment
    _out, err, status = Open3.capture3(env, File.join(env.fetch("PATH").split(":").first, "gh"), "pr", "view", "-R", "other/repo")

    expect(status.exitstatus).to eq(77)
    expect(err).to include("restricted to acme/widgets")
  end

  it "rejects destructive commands without separate authority" do
    env = access.environment
    _out, err, status = Open3.capture3(env, File.join(env.fetch("PATH").split(":").first, "gh"), "pr", "close", "9")

    expect(status.exitstatus).to eq(78)
    expect(err).to include("separately confirmed destructive authority")
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
      [ "push", "--force", "origin", "repair" ], [ "push", "origin", "+repair:repair" ] ].each do |args|
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
