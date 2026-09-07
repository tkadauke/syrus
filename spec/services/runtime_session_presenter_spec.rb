require "rails_helper"

RSpec.describe RuntimeSessionPresenter do
  let(:repository) { Factories.repository }
  let(:session) do
    RuntimeSession.create!(
      repository: repository,
      workspace_ref: "workspace-a",
      provider_key: "browser",
      display_name: "Browser",
      state: "running",
      primary: true,
      metadata: { "port" => 3001 }
    )
  end

  describe ".session_payload" do
    it "shapes the session's public fields" do
      payload = described_class.session_payload(session)

      expect(payload).to include(
        id: session.id,
        provider_key: "browser",
        display_name: "Browser",
        state: "running",
        primary: true,
        metadata: { "port" => 3001 }
      )
    end

    it "includes the active agent input lease when present" do
      lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "typing")

      payload = described_class.session_payload(session)

      expect(payload[:active_agent_input_lease]).to include(id: lease.id, owner: "agent", mode: "input")
    end

    it "is nil when there is no active agent input lease" do
      payload = described_class.session_payload(session)

      expect(payload[:active_agent_input_lease]).to be_nil
    end

    it "strips internal bookkeeping keys out of metadata" do
      session.update!(metadata: session.metadata.merge("latest_frame_document_id" => 42, "url" => "http://127.0.0.1:3001"))

      payload = described_class.session_payload(session)

      expect(payload[:metadata]).to eq("port" => 3001, "url" => "http://127.0.0.1:3001")
      expect(payload[:metadata]).not_to have_key("latest_frame_document_id")
    end
  end

  describe ".lease_payload" do
    it "returns nil for a nil lease" do
      expect(described_class.lease_payload(nil)).to be_nil
    end

    it "shapes a lease's public fields" do
      lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "user", owner_ref: "operator:1", mode: "build", reason: "reload")

      payload = described_class.lease_payload(lease)

      expect(payload).to include(id: lease.id, owner: "user", owner_ref: "operator:1", mode: "build", reason: "reload", state: "active", cancellable: true)
    end
  end
end
