module AgentProviders
  class Base
    SessionCapture = Data.define(:provider, :session_id, :transcript_jsonl, :missing_message)

    # Env vars the sidecar needs to boot Syrus's Rails app and reach
    # MySQL. Agents are launched with narrow env allowlists, then spawn
    # MCP server children from there; without forwarding these values,
    # the sidecar can boot under the wrong Rails/Bundler context.
    SIDECAR_ENV_FORWARD = %w[
      RAILS_ENV
      RAILS_MASTER_KEY
      SECRET_KEY_BASE
      RAILS_LOG_TO_STDOUT
      DB_HOST
      SYRUS_DATABASE_PASSWORD
      BUNDLE_PATH
      BUNDLE_DEPLOYMENT
      BUNDLE_WITHOUT
      TZ
    ].freeze

    def initialize(run:, workspace:, parent_session_id:)
      @run = run
      @workspace = workspace
      @parent_session_id = parent_session_id
      @workflow = run.step.workflow
      @job = workflow.job
    end

    def self.provider
      name.demodulize.underscore
    end

    def provider
      self.class.provider
    end

    def run(prompt:, log_sink:, max_turns: nil)
      raise NotImplementedError, "#{self.class.name} must implement #run"
    end

    def session_capture(result)
      return nil if result.session_id.blank?

      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: transcript_from_result(result),
        missing_message: nil
      )
    end

    private

    attr_reader :workspace, :parent_session_id, :workflow, :job

    def transcript_from_result(result)
      return result.transcript_jsonl if result.transcript_jsonl.present?
      return nil if result.transcript_path.blank? || !File.exist?(result.transcript_path)

      File.read(result.transcript_path)
    end

    def sidecar_env
      ENV.slice(*SIDECAR_ENV_FORWARD).compact
    end

    def sidecar_command
      Rails.root.join("bin/syrus-mcp-sidecar").to_s
    end

    def sidecar_args
      [ "--run-id", @run.id.to_s ]
    end
  end
end
