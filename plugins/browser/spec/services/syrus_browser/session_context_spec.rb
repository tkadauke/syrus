require "rails_helper"

RSpec.describe SyrusBrowser::SessionContext do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".resolve" do
    context "with a run-shaped server_context (workflow visual_review)" do
      let(:run) { instance_double(Run, id: 42) }

      it "resolves to the run's session key and a null artifact sink" do
        server_context = { run_id: 42 }
        allow(Mcp::Tools).to receive(:run_from_context).with(server_context).and_return(run)

        result = described_class.resolve(server_context)

        expect(result.session_key).to eq("run:42")
        expect(result.owner).to eq(run)
        expect(result.artifact_sink).to be_a(SyrusBrowser::ArtifactSinks::Null)
      end
    end

    context "with a runtime_session-shaped server_context (provider delegation)" do
      it "resolves directly to that runtime session, without touching the chat's active-session lookup" do
        chat_session = ChatSession.create!(user: user, repository: repository, mode: "coding")
        runtime_session = RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace", provider_key: "browser", display_name: "Browser"
        )

        result = described_class.resolve({ runtime_session: runtime_session })

        expect(result.session_key).to eq("runtime_session:#{runtime_session.id}")
        expect(result.owner).to eq(runtime_session)
        expect(result.artifact_sink).to be_a(SyrusBrowser::ArtifactSinks::ChatMedia)
      end
    end

    context "with a chat_session-shaped server_context (live Coding Mode chat call)" do
      let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

      it "resolves to the chat's active browser runtime session" do
        runtime_session = RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace", provider_key: "browser", display_name: "Browser", state: "running"
        )

        result = described_class.resolve({ chat_session: chat_session })

        expect(result.session_key).to eq("runtime_session:#{runtime_session.id}")
        expect(result.artifact_sink).to be_a(SyrusBrowser::ArtifactSinks::ChatMedia)
      end

      it "prefers the primary session when several browser sessions are active" do
        RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace-a", provider_key: "browser", display_name: "Browser", state: "running"
        )
        primary = RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace-b", provider_key: "browser", display_name: "Browser",
          state: "running", primary: true
        )

        result = described_class.resolve({ chat_session: chat_session })

        expect(result.session_key).to eq("runtime_session:#{primary.id}")
      end

      it "ignores stopped/failed sessions and non-browser providers" do
        RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace-stopped", provider_key: "browser", display_name: "Browser", state: "stopped"
        )
        RuntimeSession.create!(
          repository: repository, chat_session: chat_session,
          workspace_ref: "/workspace-ios", provider_key: "ios_simulator", display_name: "iOS", state: "running"
        )

        expect { described_class.resolve({ chat_session: chat_session }) }
          .to raise_error(SyrusBrowser::SessionContext::NoActiveSessionError)
      end

      it "raises when the chat has no active browser runtime session" do
        expect { described_class.resolve({ chat_session: chat_session }) }
          .to raise_error(SyrusBrowser::SessionContext::NoActiveSessionError, /no active browser runtime session/)
      end
    end
  end
end
