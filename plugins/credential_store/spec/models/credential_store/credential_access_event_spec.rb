require "rails_helper"

RSpec.describe CredentialStore::CredentialAccessEvent do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  def create_credential
    CredentialStore::Credential.create!(
      name: "Deploy token",
      credential_type: "k8s_cluster.kubeconfig",
      scope_type: "repository",
      scope_id: repo.id,
      created_by: owner,
      payload: "secret-token",
      safe_metadata: { "host" => "github.com" },
      target_constraints: { "allowed_hosts" => [ "github.com" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "git.push" ]
    )
  end

  it "records contextual access attempts without payload material" do
    job = Factories.job_with_run(user: owner, repository: repo)
    run = job.runs.first
    workflow = job.workflows.first
    credential = create_credential

    event = described_class.record!(
      credential: credential,
      user: owner,
      repository: repo,
      job: job,
      workflow: workflow,
      run: run,
      surface: "workflow",
      tool_name: "git.push",
      action: "use",
      purpose: "push branch",
      result: "allowed"
    )

    expect(event.credential).to eq(credential)
    expect(event.user).to eq(owner)
    expect(event.repository).to eq(repo)
    expect(event.job).to eq(job)
    expect(event.workflow).to eq(workflow)
    expect(event.run).to eq(run)
    expect(event.attributes.values.compact.join(" ")).not_to include("secret-token")
  end

  it "requires a denial reason only for denied access" do
    denied = described_class.new(credential: create_credential, surface: "workflow", action: "use", result: "denied")
    expect(denied).not_to be_valid
    expect(denied.errors[:denial_reason]).to include("must be present when result is denied")

    allowed = described_class.new(
      credential: create_credential,
      surface: "workflow",
      action: "use",
      result: "allowed",
      denial_reason: "wrong repo"
    )
    expect(allowed).not_to be_valid
    expect(allowed.errors[:denial_reason]).to include("must be blank unless result is denied")
  end

  it "validates surface, action, result, and tool name vocabulary" do
    event = described_class.new(
      credential: create_credential,
      surface: "terminal",
      action: "dump",
      result: "maybe",
      tool_name: "Bad Tool"
    )

    expect(event).not_to be_valid
    expect(event.errors[:surface]).to be_present
    expect(event.errors[:action]).to be_present
    expect(event.errors[:result]).to be_present
    expect(event.errors[:tool_name]).to be_present
  end

  it "is append-only" do
    event = described_class.record!(
      credential: create_credential,
      surface: "workflow",
      action: "test",
      result: "allowed"
    )

    expect { event.update!(purpose: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
