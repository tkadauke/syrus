module Coworkers
  class JournalingActivity
    def initialize(coworker:, date:)
      @coworker = coworker
      @date = date
    end

    def active?
      messages.exists? || background_jobs.exists? || daily_memory.present?
    end

    def material
      sections = []
      sections << "### Daily memory\n\n#{daily_memory}" if daily_memory.present?
      if messages.exists?
        lines = messages.order(:created_at).limit(500).map do |message|
          "- CHAT-#{message.chat_session_id} #{message.created_at.iso8601} #{message.role}: #{message.extract_text_from_content.to_s.truncate(1_000)}"
        end
        sections << "### Messages\n\n#{lines.join("\n")}"
      end
      if background_jobs.exists?
        lines = background_jobs.order(:created_at).limit(100).map do |job|
          summary = Run.where(job_id: job.id).where.not(agent_summary: [ nil, "" ]).order(:created_at).last&.agent_summary
          "- JOB-#{job.id}: #{job.issue_title}#{": #{summary.to_s.truncate(1_000)}" if summary.present?}"
        end
        sections << "### Background runs\n\n#{lines.join("\n")}"
      end
      sections.presence&.join("\n\n") || "No material was found."
    end

    private

    def zone
      ActiveSupport::TimeZone[@coworker.owner_user.approval_delivery_preferences["time_zone"].to_s] || ActiveSupport::TimeZone["UTC"]
    end

    def range = @date.in_time_zone(zone).all_day

    def chat_ids
      @chat_ids ||= (
        @coworker.chats.ids +
        Coworkers::ChatAgent.where(coworker: @coworker).pluck(:chat_session_id) +
        @coworker.received_chat_shares.pluck(:chat_session_id)
      ).uniq
    end

    def messages = ChatMessage.where(chat_session_id: chat_ids, created_at: range)

    def background_jobs
      Job.where(origin: "coworkers", origin_id: @coworker.id.to_s, created_at: range)
    end

    def daily_memory
      return @daily_memory if defined?(@daily_memory)

      repository = @coworker.workspace_repository
      return @daily_memory = nil unless repository
      if (chat = @coworker.coworker_chats.find_by(role: "main")&.chat_session)
        root = ChatWorkspace.repo_path_for(chat, repository)
        local = root.join("memory/daily/#{@date.iso8601}.md")
        pending = read_workspace_file(root, local)
        return @daily_memory = pending if pending
      end
      reader = RepositoryContent.for(repository, user: @coworker.owner_user)
      revision = reader.resolve("coworkers/#{@coworker.handle}")
      @daily_memory = reader.read(revision, "memory/daily/#{@date.iso8601}.md", max_bytes: 64.kilobytes).text
    rescue RepositoryContent::NotFound, RepositoryContent::Unavailable, RepositoryContent::Unsupported, RepositoryContent::UnknownRevision
      @daily_memory = nil
    end

    def read_workspace_file(root, path)
      root = root.realpath
      relative = path.relative_path_from(root)
      current = root
      relative.each_filename do |part|
        current = current.join(part)
        return if current.symlink?
      end

      resolved = path.realpath
      return unless resolved.to_s.start_with?("#{root}#{File::SEPARATOR}")

      File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(64.kilobytes) }
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, ArgumentError
      nil
    end
  end
end
