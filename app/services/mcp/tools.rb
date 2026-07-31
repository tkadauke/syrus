require "base64"

module Mcp
  module Tools
    HEAD_TAIL_BYTES = 4.kilobytes

    class CurrentMessage
      def initialize(chat_session)
        @chat_session = chat_session
      end

      def update_columns(attributes)
        message&.update_columns(attributes)
      end

      private

      def message
        @chat_session.messages.where(role: "assistant").order(created_at: :desc, id: :desc).first
      end
    end

    class << self
      def run_from_context(server_context)
        with_database_connection do
          run_id = server_context[:run_id] || server_context[:run]&.id
          Run.find(run_id)
        end
      end

      def with_database_connection
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.verify! if connection.respond_to?(:verify!)
          yield
        end
      end

      # Append a JobLog row from the sidecar process. Same shape as
      # RunJob#log so MCP-driven lines blend into the rest of the
      # transcript and broadcast live via JobLog#broadcasts_to.
      def write_log(run, chunk)
        with_database_connection do
          JobLog.append!(run: run, chunk: chunk)
        end
      end

      def success(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      end

      def image_result(jpeg:, text: nil, mime_type: "image/jpeg")
        content = [ { type: "image", data: Base64.strict_encode64(jpeg), mimeType: mime_type } ]
        content << { type: "text", text: text } if text.present?
        MCP::Tool::Response.new(content)
      end

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end

      def unauthorized(message)
        MCP::Tool::Response.new([ { type: "text", text: "Unauthorized: #{message}" } ], error: true)
      end

      def not_authorized
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(error: "not_authorized") } ], error: true)
      end

      def tool_error(reason)
        MCP::Tool::Response.new([ { type: "text", text: reason } ], error: true)
      end

      def utf8(text)
        string = text.to_s
        if string.encoding == Encoding::ASCII_8BIT
          string.dup.force_encoding(Encoding::UTF_8).scrub("")
        else
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        end
      end

      def truncate_text(text, max_bytes)
        text = text.to_s
        return { text: text, truncated: false, bytes: text.bytesize } if text.bytesize <= max_bytes

        {
          text: safe_byteslice(text, 0, max_bytes),
          truncated: true,
          bytes: text.bytesize,
          omitted_bytes: text.bytesize - max_bytes
        }
      end

      def head_tail(text, bytes: HEAD_TAIL_BYTES)
        text = text.to_s
        return { head: text, tail: "", truncated: false, bytes: text.bytesize } if text.bytesize <= bytes * 2

        {
          head: safe_byteslice(text, 0, bytes),
          tail: safe_byteslice(text, -bytes, bytes),
          truncated: true,
          bytes: text.bytesize,
          omitted_bytes: text.bytesize - (bytes * 2)
        }
      end

      def proposal_payload(proposal)
        {
          id: proposal.id,
          slug: proposal.slug,
          title: proposal.title,
          body: proposal.body,
          kind: proposal.kind,
          state: proposal.state,
          labels: labels_for(proposal),
          dependencies: proposal.dependencies.order(:slug).pluck(:slug),
          depends_on_epic_ids: Array(proposal.depends_on_epic_ids),
          depends_on_job_ids: Array(proposal.depends_on_job_ids),
          depends_on_proposal_slugs: proposal.epic_dependency_tokens.reject { |token| token.match?(/\Aepic:\d+\z/) },
          repository: proposal.effective_repository&.slug,
          target_epic: target_epic_payload(proposal),
          materialized: materialized_payload(proposal)
        }
      end

      def materialized_payload(proposal)
        return { kind: "rejected", reason: proposal.state } if proposal.rejected? || proposal.withdrawn?

        case proposal.materialized_record
        when Job
          {
            kind: "job",
            job_id: proposal.job.id,
            job_title: proposal.job.issue_title,
            job_state: proposal.job.state
          }
        when Epic
          {
            kind: "epic",
            epic_id: proposal.epic.id,
            epic_title: proposal.epic.title,
            child_jobs: proposal.child_proposals.confirmed.includes(:job).map do |child|
              { job_id: child.job_id, title: child.job&.issue_title }
            end
          }
        end
      end

      def target_epic_payload(proposal)
        return unless proposal.target_epic

        { id: proposal.target_epic.id, number: proposal.target_epic.number, label: proposal.target_epic.slug }
      end

      def labels_for(proposal)
        raw = proposal.labels
        return [] if raw.blank?
        return raw if raw.is_a?(Array)

        JSON.parse(raw)
      rescue JSON::ParserError
        Array(raw)
      end

      def broadcast_proposal_created(chat_session, proposal)
        AppEvents.broadcast(
          user: chat_session.user,
          type: "updated",
          resource: "chat",
          id: chat_session.id,
          changed: [ "proposal" ],
          payload: {
            action: "update_proposal",
            proposal_id: proposal.id
          }
        )
      end

      def safe_byteslice(text, start, length)
        text.to_s.safe_byteslice(start, length)
      end
    end
  end
end
