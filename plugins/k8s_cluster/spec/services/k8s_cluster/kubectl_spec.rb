require "rails_helper"

RSpec.describe K8sCluster::Kubectl do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:run) { job.runs.first }
  let(:context) { McpToolContext.from_run(run) }
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

    allow(runner).to receive(:call) do |env:, argv:|
      observed_kubeconfig_path = env.fetch("KUBECONFIG")

      expect(File.stat(observed_kubeconfig_path).mode & 0o777).to eq(0o600)
      expect(File.read(observed_kubeconfig_path)).to eq(kubeconfig)
      expect(argv).to eq([ "kubectl", "--context", "prod", "--namespace", "default", "get", "pods" ])

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

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "secrets", "-o", "yaml" ])
    }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /expose secret values/)
    expect(runner).not_to have_received(:call)
  end

  it "requires explicit allowance for mutating kubectl commands" do
    credential = create_credential

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "apply", "-f", "deployment.yaml" ])
    }.to raise_error(K8sCluster::Kubectl::RiskyCommand, /risky-command allowance/)

    allow(runner).to receive(:call).and_return(K8sCluster::KubectlRunner::Result.new(stdout: "configured\n", stderr: "", status: 0))

    result = described_class.call(
      context: context,
      credential: credential.id,
      kube_context: "prod",
      args: [ "apply", "-f", "deployment.yaml" ],
      allow_risky_command: true
    )

    expect(result[:ok]).to be(true)
  end

  it "does not let chat callers self-authorize risky commands or secret output" do
    credential = create_credential(allowed_surfaces: [ "chat" ])

    expect {
      described_class.call(
        context: chat_context,
        credential: credential.id,
        kube_context: "prod",
        args: [ "delete", "pod", "web" ],
        allow_risky_command: true
      )
    }.to raise_error(K8sCluster::Kubectl::OperatorConfirmationRequired, /risky commands/)

    expect {
      described_class.call(
        context: chat_context,
        credential: credential.id,
        kube_context: "prod",
        args: [ "get", "secrets", "-o", "yaml" ],
        allow_secret_output: true
      )
    }.to raise_error(K8sCluster::Kubectl::OperatorConfirmationRequired, /secret output/)
  end

  it "rejects kubeconfig, context, and namespace flags in kubectl args" do
    credential = create_credential

    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods", "--kubeconfig=/tmp/config" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /credential flags/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "--context", "staging", "get", "pods" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /context/)
    expect {
      described_class.call(context: context, credential: credential.id, kube_context: "prod", args: [ "get", "pods", "-n", "prod" ])
    }.to raise_error(K8sCluster::Kubectl::InvalidCommand, /namespace/)
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
