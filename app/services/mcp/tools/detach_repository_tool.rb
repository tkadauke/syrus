require "mcp"

module Mcp::Tools
  class DetachRepositoryTool < MCP::Tool
    tool_name "detach_repository"

    description "Detach a repository (by owner/name slug) that is currently attached to this chat session."

    input_schema(
      properties: {
        slug: { type: "string", description: "Repository slug, for example tkadauke/syrus." }
      },
      required: %w[slug]
    )

    class << self
      def call(slug:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        owner, name = normalize_slug(slug)
        return Mcp::Tools.invalid("slug must be owner/name") unless owner && name

        # Only repositories currently attached to this chat are eligible —
        # mirrors the controller's destroy_attachment scoping via
        # chat_session.chat_attachments, so there is no cross-chat/cross-user
        # attachment risk to guard against separately.
        repository = chat_session.attached_repositories.find { |r| r.owner.casecmp?(owner) && r.name.casecmp?(name) }
        return Mcp::Tools.invalid("repository #{owner}/#{name} is not attached to this chat") unless repository

        was_effective_repository = chat_session.repository == repository

        attachment = chat_session.chat_attachments.find_by(attachable_type: "Repository", attachable_id: repository.id)
        return Mcp::Tools.invalid("repository #{owner}/#{name} is not attached to this chat") unless attachment

        attachment.destroy!
        chat_session.association(:repository_attachments).reset
        chat_session.association(:attached_repositories).reset

        remaining = chat_session.attached_repositories.map { |r| { id: r.id, slug: r.slug } }

        Mcp::Tools.success(
          repository: { id: repository.id, slug: repository.slug },
          detached: true,
          remaining_repositories: remaining,
          note: detach_note(was_effective_repository, remaining)
        )
      rescue StandardError => e
        Rails.logger.warn("[Mcp::Tools] detach_repository failed for #{slug}: #{e.class}: #{e.message}")
        Mcp::Tools.invalid("failed to detach #{slug}: #{e.message}")
      end

      private

      def detach_note(was_effective_repository, remaining)
        return unless was_effective_repository

        if remaining.empty?
          "This was the chat's only attached repository. Attach a repository before browsing source or filing repo-scoped work."
        else
          "This was the chat's effective repository. #{remaining.first[:slug]} is now effective for file browsing and repo-scoped actions."
        end
      end

      def normalize_slug(slug)
        parts = slug.to_s.strip.split("/", 2)
        return unless parts.length == 2
        return if parts.any?(&:blank?)

        parts
      end
    end
  end
end
