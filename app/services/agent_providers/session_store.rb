module AgentProviders
  class SessionStore
    def self.transcript_for(provider:, session_id:, job:)
      return nil if provider.blank? || session_id.blank? || job.blank?

      ClaudeSession.for_runs
                   .where(session_id: session_id, provider: provider, runs: { job_id: job.id })
                   .where.not(transcript_jsonl: nil)
                   .order(created_at: :desc)
                   .first&.transcript_jsonl
    end

    def initialize(run:, log:)
      @run = run
      @log = log
    end

    def capture!(capture)
      return unless capture

      if capture.transcript_jsonl.blank?
        log(capture.missing_message) if capture.missing_message.present?
        log("[agent_session] no transcript captured for #{capture.provider} session #{capture.session_id}")
        return
      end

      ClaudeSession.create!(
        resumable: @run,
        provider: capture.provider,
        session_id: capture.session_id,
        transcript_jsonl: utf8(capture.transcript_jsonl)
      )
      log("[agent_session] captured #{capture.provider} #{capture.session_id} (#{capture.transcript_jsonl.bytesize} bytes)")
    rescue StandardError => e
      log("[agent_session] capture failed: #{e.class}: #{e.message}")
    end

    private

    def log(message)
      @log.call(message)
    end

    def utf8(text)
      string = text.to_s
      if string.encoding == Encoding::ASCII_8BIT
        string.dup.force_encoding(Encoding::UTF_8).scrub("")
      else
        string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      end
    end
  end
end
