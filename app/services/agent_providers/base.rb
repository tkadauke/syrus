require "tmpdir"

module AgentProviders
  class Base
    SessionCapture = Data.define(:provider, :session_id, :transcript_jsonl, :missing_message)

    # Env vars the sidecar needs to boot Syrus's Rails app and reach
    # MySQL. Agents are launched with narrow env allowlists, then spawn
    # MCP server children from there; without forwarding these values,
    # the sidecar can boot under the wrong Rails/Bundler context.
    #
    # The S3_* vars are required because production sets
    # `config.active_storage.service = :minio`, and Rails eagerly
    # builds the S3Service at boot under `eager_load = true`. With
    # S3_BUCKET unset, `Aws::S3::Resource#bucket(nil)` raises
    # `ArgumentError: missing required option :name` mid-boot, the
    # sidecar dies before responding to claude's MCP `initialize`, and
    # the agent sees "connection closed: initialize response
    # (code -32603)". The worker pod has these injected by the
    # green_acres deployment; we just need to thread them through the
    # subprocess boundary the same way as RAILS_ENV / DB_HOST.
    SIDECAR_ENV_FORWARD = %w[
      RAILS_ENV
      RAILS_MASTER_KEY
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
      SECRET_KEY_BASE
      RAILS_LOG_LEVEL
      RAILS_LOG_TO_STDOUT
      DATABASE_URL
      DB_HOST
      SYRUS_DATABASE_PASSWORD
      SYRUS_SQLITE
      SYRUS_DATA_ROOT
      BUNDLE_PATH
      BUNDLE_DEPLOYMENT
      BUNDLE_WITHOUT
      TZ
      SYRUS_APP_HOST
      SYRUS_ALLOWED_HOSTS
      SYRUS_ASSUME_SSL
      SYRUS_FORCE_SSL
      S3_BUCKET
      S3_ENDPOINT
      S3_REGION
      S3_ACCESS_KEY_ID
      S3_SECRET_ACCESS_KEY
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
      invoke(
        workspace_path: workspace.path,
        prompt: prompt,
        log_sink: log_sink,
        timeout: invocation_timeout,
        max_turns: max_turns || default_max_turns,
        mcp: true,
        resume_session_id: parent_session_id
      )
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      Dir.mktmpdir("syrus-agent-once") do |tmpdir|
        invoke(
          workspace_path: tmpdir,
          prompt: prompt,
          log_sink: log_sink,
          timeout: timeout,
          max_turns: max_turns,
          mcp: false,
          resume_session_id: nil
        )
      end
    end

    def record_result!(result, log:)
      updates = {}
      updates[:agent_turns] = result.turns if result.turns
      updates[:agent_outcome] = result.outcome if result.outcome
      updates[:cost_usd] = result.cost_usd if result.cost_usd
      updates[:input_tokens] = result.input_tokens if result.input_tokens
      updates[:output_tokens] = result.output_tokens if result.output_tokens
      updates[:cache_creation_input_tokens] = result.cache_creation_input_tokens if result.cache_creation_input_tokens
      updates[:cache_read_input_tokens] = result.cache_read_input_tokens if result.cache_read_input_tokens
      @run.update!(updates) if updates.any?

      SessionStore.new(run: @run, log: log).capture!(session_capture(result))
      result
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

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, max_turns:, mcp:, resume_session_id:)
      raise NotImplementedError, "#{self.class.name} must implement #invoke"
    end

    def invocation_timeout
      AgentInvocation::DEFAULT_TIMEOUT_SECONDS
    end

    def default_max_turns
      job.user.agent_max_turns
    end

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
