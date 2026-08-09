module Prompts
  # Shared context block for Jobs that belong to an Epic. This gives the
  # agent enough architectural orientation to keep sibling Jobs coherent
  # without expanding the scope of the current task.
  class EpicContext
    MAX_DESCRIPTION_BYTES = 16.kilobytes

    def initialize(epic:, job: nil)
      @epic = epic
      @job = job
    end

    def to_s
      return "" unless @epic

      description = @epic.description.to_s.strip
      parts = [
        "## Epic context (orientation only)",
        "This Job belongs to #{@epic.slug}: #{@epic.title}.",
        scope_guard
      ]
      parts << "Epic description:\n\n#{truncated_description(description)}" if description.present?
      siblings_section = approved_siblings_section
      parts << siblings_section if siblings_section
      parts.join("\n\n")
    end

    private

    def scope_guard
      "Use this Epic context only to understand how the current Job fits into the larger plan. " \
        "Do not implement the entire Epic. Do not implement sibling Jobs or unrelated work from " \
        "the Epic description. Implement only the Job described above."
    end

    def truncated_description(description)
      return description if description.bytesize <= MAX_DESCRIPTION_BYTES

      "#{description.safe_byteslice(0, MAX_DESCRIPTION_BYTES)}\n\n" \
        "[Epic description truncated after #{MAX_DESCRIPTION_BYTES} bytes.]"
    end

    def approved_siblings_section
      return nil unless @job

      exclude_ids = [ @job.id ].compact
      siblings = @epic.jobs.where(state: %w[approved landing]).where.not(id: exclude_ids)
      return nil if siblings.empty?

      lines = siblings.map { |j| "#{j.slug}: #{j.title}" }

      <<~SECTION.strip
        ## Approved sibling Jobs

        #{lines.join("\n")}

        These sibling Jobs have been approved and their changes are already in your working directory. Inspect the code they introduced before implementing to maintain consistent patterns.
      SECTION
    end
  end
end
