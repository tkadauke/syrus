require "rails_helper"

RSpec.describe McpInvocationContext do
  let(:worker_id) { "worker-#{SecureRandom.hex(4)}" }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "run surface" do
    let(:run) { Factories.job(repository: repository).initial_run }

    it "resolves the same McpToolContext.from_run would build directly" do
      token = described_class.issue_for_run(run, worker_id: worker_id, provider: "claude")

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.surface).to eq(:run)
      expect(resolved.provider).to eq("claude")
      expect(resolved.tool_context.surface).to eq(:run)
      expect(resolved.tool_context.run).to eq(run)
      expect(resolved.tool_context.job).to eq(run.job)
      expect(resolved.tool_context.workflow).to eq(run.workflow)
      expect(resolved.tool_context.user).to eq(run.job.user)
      expect(resolved.tool_context.repository).to eq(run.job.repository)
      expect(resolved.tool_context.role).to eq(McpToolContext.from_run(run).role)
    end

    it "resolves app API run tokens without accepting daemon MCP tokens for that audience" do
      app_token = described_class.issue_for_app_run(run, provider: "codex")
      mcp_token = described_class.issue_for_run(run, worker_id: worker_id, provider: "codex")

      resolved = described_class.resolve_for_app_api(app_token)

      expect(resolved.surface).to eq(:run)
      expect(resolved.provider).to eq("codex")
      expect(resolved.tool_context.run).to eq(run)
      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Malformed/))
      expect { described_class.resolve_for_app_api(mcp_token) }
        .to raise_error(described_class::Malformed, /not valid for app API/)
    end

    it "re-derives role live from the current step kind instead of trusting a stale claim" do
      token = described_class.issue_for_run(run, worker_id: worker_id)
      run.step.update_columns(kind: "adversarial_review")

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.tool_context.role).to eq(AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER)
    end

    it "rejects a token whose run no longer exists as unauthorized" do
      token = described_class.issue_for_run(run, worker_id: worker_id)
      run_id = run.id
      run.step.destroy!
      run.workflow.destroy!
      run.destroy!

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Unauthorized/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::Unauthorized, /run #{run_id} not found/)
    end
  end

  describe "macOS worker app API surface" do
    it "resolves to a scoped machine context for the app API audience" do
      token = described_class.issue_for_app_macos_worker(expires_in: 5.minutes)

      resolved = described_class.resolve_for_app_api(token)

      expect(resolved.surface).to eq(:macos_worker)
      expect(resolved.tool_context).to be_macos_worker
      expect(resolved.tool_context.user).to be_nil
    end

    it "expires like other app API invocation contexts" do
      token = described_class.issue_for_app_macos_worker(expires_in: -1.minute)

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Expired/))
      expect { described_class.resolve_for_app_api(token) }
        .to raise_error(described_class::Expired)
    end
  end

  describe "chat surface" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
    let(:message) { chat_session.messages.create!(role: "user", content: { "text" => "hi" }) }

    it "resolves the same McpToolContext.from_chat_session would build directly, plus surface-only fields" do
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: message,
        tier: "deferred",
        evaluator: false,
        scoped_event_id: 42,
        evaluator_session_id: "eval-session-1",
        provider: "codex"
      )

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.surface).to eq(:chat)
      expect(resolved.tier).to eq("deferred")
      expect(resolved.provider).to eq("codex")
      expect(resolved.current_message_id).to eq(message.id)
      expect(resolved.scoped_event_id).to eq(42)
      expect(resolved.evaluator_session_id).to eq("eval-session-1")
      expect(resolved.tool_context.surface).to eq(:chat)
      expect(resolved.tool_context.chat_session).to eq(chat_session)
      expect(resolved.tool_context.user).to eq(chat_session.user)
      expect(resolved.tool_context.role).to eq(McpToolContext.from_chat_session(chat_session).role)
    end

    it "reconstructs the evaluator role when the token claims evaluator: true" do
      token = described_class.issue_for_chat(chat_session, worker_id: worker_id, evaluator: true)

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.tool_context.role).to eq(AgentRole::CHAT_EVALUATOR)
    end

    it "resolves a turn-scoped token after the old default window but before the chat turn ceiling" do
      token = travel_to(10.minutes.ago) do
        described_class.issue_for_chat(
          chat_session,
          worker_id: worker_id,
          current_message: message,
          expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
        )
      end

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.tool_context.chat_session).to eq(chat_session)
      expect(resolved.current_message_id).to eq(message.id)
    end

    it "keeps resolving a turn-scoped token after streamed tool messages while the agent process is still live" do
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: message,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
      SpawnedProcess.create!(
        chat_session: chat_session,
        kind: "agent",
        command: "codex exec",
        hostname: "worker-1",
        pid: 12_345,
        started_at: Time.current,
        workdir: chat_session.workspace_root.to_s
      )
      chat_session.messages.create!(
        role: "tool_use",
        tool_name: "read_file",
        tool_use_id: "toolu_1",
        content: {
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "read_file",
          "input" => { "path" => "README.md" }
        }
      )
      expect(chat_session.reload).not_to be_turn_in_flight
      expect(chat_session).to be_agent_busy

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.tool_context.chat_session).to eq(chat_session)
      expect(resolved.current_message_id).to eq(message.id)
    end

    it "rejects a turn-scoped token once that message is no longer in flight" do
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: message,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
      chat_session.messages.create!(role: "assistant", content: { "text" => "done" })
      expect(chat_session.reload).not_to be_turn_in_flight

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/TurnEnded/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::TurnEnded, /message #{message.id} is no longer active/)
    end

    it "rejects an earlier turn token while a later message on the same chat is now in flight" do
      earlier_message = message
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: earlier_message,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
      chat_session.messages.create!(role: "assistant", content: { "text" => "done" })
      later_message = chat_session.messages.create!(role: "user", content: { "text" => "again" })
      expect(chat_session.reload).to be_turn_in_flight

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/TurnEnded/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::TurnEnded, /message #{earlier_message.id} is no longer active/)
      expect(later_message.id).not_to eq(earlier_message.id)
    end

    # Regression: MCP tokens are scoped to the message a turn is running for,
    # but the active turn used to be inferred as "the last user message". A
    # turn started by a non-user message -- a proposal confirmation, say --
    # therefore had its own token rejected as TurnEnded, and the turn failed
    # during MCP startup with "required MCP servers failed to initialize".
    it "accepts the token of a turn started by a non-user message" do
      earlier_user_message = message
      system_message = chat_session.messages.create!(
        role: "system",
        content: { "text" => "Proposal confirmed." }
      )
      chat_session.begin_turn_for!(system_message)
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: system_message,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
      # The inference this replaces would name the user message here, not the
      # system message the turn is actually running for.
      expect(chat_session.messages.where(role: "user").order(:created_at, :id).last)
        .to eq(earlier_user_message)

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.current_message_id).to eq(system_message.id)
    end

    it "still rejects an earlier token once a later turn claims the chat" do
      token = described_class.issue_for_chat(
        chat_session,
        worker_id: worker_id,
        current_message: message,
        expires_in: AgentInvocation::DEFAULT_TIMEOUT_SECONDS.seconds
      )
      later_message = chat_session.messages.create!(role: "system", content: { "text" => "next" })
      chat_session.begin_turn_for!(later_message)

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/TurnEnded/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::TurnEnded, /message #{message.id} is no longer active/)
    end

    it "rejects a token whose chat session no longer exists as unauthorized" do
      token = described_class.issue_for_chat(chat_session, worker_id: worker_id)
      chat_session_id = chat_session.id
      chat_session.destroy!

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Unauthorized/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::Unauthorized, /chat session #{chat_session_id} not found/)
    end
  end

  describe "rejection handling" do
    let(:run) { Factories.job(repository: repository).initial_run }

    it "rejects a blank token as malformed" do
      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Malformed/))
      expect { described_class.resolve("", worker_id: worker_id) }
        .to raise_error(described_class::Malformed)
    end

    it "rejects garbage input as malformed" do
      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Malformed/))
      expect { described_class.resolve("not-a-real-token", worker_id: worker_id) }
        .to raise_error(described_class::Malformed)
    end

    it "rejects a tampered (re-signed by a different verifier) token as malformed" do
      token = described_class.issue_for_run(run, worker_id: worker_id)
      forged = Rails.application.message_verifier(:some_other_purpose).generate(
        Rails.application.message_verifier(described_class::MESSAGE_VERIFIER_PURPOSE).verify(token)
      )

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Malformed/))
      expect { described_class.resolve(forged, worker_id: worker_id) }
        .to raise_error(described_class::Malformed)
    end

    it "rejects an expired token" do
      token = travel_to(1.hour.ago) { described_class.issue_for_run(run, worker_id: worker_id, expires_in: 5.minutes) }
      run.update_columns(state: "failed", finished_at: 55.minutes.ago)

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Expired/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::Expired)
    end

    it "accepts an expired token while its run is still active" do
      token = travel_to(10.minutes.ago) { described_class.issue_for_run(run, worker_id: worker_id, expires_in: 5.minutes) }
      run.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

      resolved = described_class.resolve(token, worker_id: worker_id)

      expect(resolved.tool_context.run).to eq(run)
    end

    it "rejects a terminal run token even before its timestamp expires" do
      token = described_class.issue_for_run(run, worker_id: worker_id, expires_in: 5.minutes)
      run.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Expired/))
      expect { described_class.resolve(token, worker_id: worker_id) }
        .to raise_error(described_class::Expired, /run #{run.id} ended/)
    end

    it "accepts a token that has not yet expired" do
      token = travel_to(4.minutes.ago) { described_class.issue_for_run(run, worker_id: worker_id, expires_in: 5.minutes) }

      expect { described_class.resolve(token, worker_id: worker_id) }.not_to raise_error
    end

    it "keeps run tokens on the shared five-minute default expiry" do
      issued_at = Time.current.change(usec: 0)
      token = travel_to(issued_at) { described_class.issue_for_run(run, worker_id: worker_id) }

      payload = Rails.application.message_verifier(described_class::MESSAGE_VERIFIER_PURPOSE).verify(token)

      expect(payload.fetch("surface")).to eq("run")
      expect(payload.fetch("exp")).to eq((issued_at + described_class::DEFAULT_EXPIRES_IN).to_i)
    end

    it "rejects a token minted for a different worker" do
      token = described_class.issue_for_run(run, worker_id: "worker-issuer")

      expect(Rails.logger).to receive(:warn).with(a_string_matching(/WrongWorker/))
      expect { described_class.resolve(token, worker_id: "worker-dispatcher") }
        .to raise_error(described_class::WrongWorker)
    end
  end

  describe "context isolation between two different invocations" do
    let(:run_a) { Factories.job(repository: repository).initial_run }
    let(:run_b) { Factories.job(repository: repository).initial_run }
    let(:chat_a) { ChatSession.create!(user: user, repository: repository) }
    let(:chat_b) { ChatSession.create!(user: user, repository: repository) }

    it "keeps two run tokens resolving to their own run regardless of resolution order" do
      token_a = described_class.issue_for_run(run_a, worker_id: worker_id)
      token_b = described_class.issue_for_run(run_b, worker_id: worker_id)

      resolved_b = described_class.resolve(token_b, worker_id: worker_id)
      resolved_a = described_class.resolve(token_a, worker_id: worker_id)

      expect(resolved_a.tool_context.run).to eq(run_a)
      expect(resolved_b.tool_context.run).to eq(run_b)
      expect(resolved_a.tool_context.job).to eq(run_a.job)
      expect(resolved_b.tool_context.job).to eq(run_b.job)

      # Re-resolving token_a after token_b was resolved must still return
      # run_a's data -- proves resolution is a pure function of the token,
      # not something cached/mutated by the previous call.
      expect(described_class.resolve(token_a, worker_id: worker_id).tool_context.run).to eq(run_a)
    end

    it "keeps two chat tokens with distinct claims isolated regardless of resolution order" do
      token_a = described_class.issue_for_chat(chat_a, worker_id: worker_id, tier: "essential", scoped_event_id: 1)
      token_b = described_class.issue_for_chat(chat_b, worker_id: worker_id, tier: "deferred", scoped_event_id: 2)

      resolved_b = described_class.resolve(token_b, worker_id: worker_id)
      resolved_a = described_class.resolve(token_a, worker_id: worker_id)

      expect(resolved_a.tool_context.chat_session).to eq(chat_a)
      expect(resolved_a.tier).to eq("essential")
      expect(resolved_a.scoped_event_id).to eq(1)

      expect(resolved_b.tool_context.chat_session).to eq(chat_b)
      expect(resolved_b.tier).to eq("deferred")
      expect(resolved_b.scoped_event_id).to eq(2)
    end

    it "does not leak context across concurrent resolutions on different threads" do
      token_a = described_class.issue_for_run(run_a, worker_id: worker_id)
      token_b = described_class.issue_for_run(run_b, worker_id: worker_id)
      results = []
      mutex = Mutex.new

      threads = [ token_a, token_b ].map do |token|
        Thread.new do
          resolved = described_class.resolve(token, worker_id: worker_id)
          mutex.synchronize { results << resolved.tool_context.run.id }
        end
      end
      threads.each(&:join)

      expect(results.sort).to eq([ run_a.id, run_b.id ].sort)
    end
  end
end
