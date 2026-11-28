require "rails_helper"

# A step that ran the failing command declared why it failed. That answer is
# a fact about the command (its exit status, its own output); everything the
# classifier could infer from text is a guess, and the guesses have been
# wrong -- a `timeout` gem read as a timed-out install, a backtrace frame
# read as a transient provider failure. So a declared code must win, and the
# text must not even be read.
RSpec.describe RunFailureClassifier do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  # Text that every text branch would happily misread: transient-sounding,
  # timeout-sounding, auth-sounding, plus a Syrus system line.
  def misleading_text = <<~TEXT
    Fetching timeout 0.6.1
    /opt/syrus/rubies/3.4.10/lib/ruby/3.4.0/bundler/settings.rb:159:in 'Bundler::Settings#temporary'
    Authentication failed; service unavailable; connection reset; overloaded, retry later
    execution expired
  TEXT

  def declare!(step_kind:, code:, error_class: "Steps::Base::StepFailed")
    run.step.update!(kind: step_kind)
    run.update!(state: "failed", agent_provider: "codex")
    RunDiagnostic.create!(run: run, error_class: error_class,
                          error_message: "#{step_kind} failed\n#{misleading_text}", problem_code: code)
    run.job_logs.create!(sequence: 900, kind: "agent", chunk: misleading_text)
    run.job_logs.create!(sequence: 901, kind: "system", chunk: "deferred landing after a transient failure")
  end

  declared = {
    "prepare" => %w[prepare_install_failed prepare_network_transient timeout validation_or_user_error],
    "push" => %w[git_transport_transient git_conflict git_ref_missing git_auth_denied branch_diverged],
    "pr_open" => %w[github_api_transient github_api_rate_limited github_api_rejected],
    "grader" => %w[grader_failure timeout]
  }

  declared.each do |step_kind, codes|
    codes.each do |code|
      it "returns the #{code} a non-agentic #{step_kind} step declared, with the registry's retryability" do
        declare!(step_kind: step_kind, code: code)
        expect(Step::Kind.fetch(step_kind).agentic).to eq(false)

        result = described_class.classify(run.reload)

        expect(result.classification).to eq(code)
        expect(result.confidence).to eq(1.0)
        expect(result.retryable).to eq(Problem::Kind.retryable?(code))
      end
    end
  end

  it "never reads the run's text once a code was declared" do
    declare!(step_kind: "prepare", code: "prepare_install_failed")
    classifier = described_class.new(run.reload)
    %i[searchable_text provider_transient_text provider_failure_text provider_terminal_log_text].each do |reader|
      allow(classifier).to receive(reader).and_raise("text was read: #{reader}")
    end

    expect(classifier.classify.classification).to eq("prepare_install_failed")
  end

  it "persists the declared answer and AutoRetryFailureClassifier agrees it is not retryable" do
    declare!(step_kind: "prepare", code: "prepare_install_failed")

    record = described_class.persist!(run.reload)
    retry_decision = AutoRetryFailureClassifier.call(workflow: run.workflow)

    expect(record).to have_attributes(classification: "prepare_install_failed", retryable: false)
    expect(retry_decision.retryable?).to eq(false)
  end

  # The control: the same text with nothing declared is misread, which is the
  # whole reason the declaration has to win.
  it "misreads the same text when nothing was declared" do
    declare!(step_kind: "prepare", code: nil)

    expect(described_class.classify(run.reload).classification).not_to eq("prepare_install_failed")
  end
end
