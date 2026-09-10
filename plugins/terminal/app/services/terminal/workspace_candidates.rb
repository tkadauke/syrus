require "set"

module Terminal
  class WorkspaceCandidates
    DEFAULT_SECTION_LIMIT = 3
    SEARCH_LIMIT = 50

    def self.for(user:, query: nil)
      new(user: user, query: query).as_json
    end

    def self.find(user:, key:)
      new(user: user).candidate_for_key(key)&.as_json
    end

    attr_reader :user, :query

    def initialize(user:, query: nil)
      @user = user
      @query = query.to_s.strip.downcase
    end

    def as_json
      filtered_candidates.map(&:as_json)
    end

    def candidate_for_key(key)
      all_candidates.find { |candidate| candidate.key == key.to_s }
    end

    private

    def filtered_candidates
      matches = if query.present?
        all_candidates.select { |candidate| candidate.matches?(query) }
      else
        all_candidates
      end

      matches.sort_by(&:sort_key).first(SEARCH_LIMIT)
    end

    def all_candidates
      @all_candidates ||= [
        *workflow_candidates,
        *chat_candidates,
        *worker_candidates
      ]
    end

    def workflow_candidates
      workflows = user.workflows
        .includes(job: :repository)
        .order(created_at: :desc)
        .limit(80)
        .to_a
      queue_names = WorkflowQueueNames.new(workflows).to_h

      workflows.map { |workflow| WorkflowCandidate.new(workflow, queue_name: queue_names[workflow.id]) }
    end

    def chat_candidates
      user.accessible_chat_sessions
        .active
        .visible
        .where.not(workspace_path: [ nil, "" ])
        .includes(:attached_repositories)
        .order(Arel.sql("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) DESC"))
        .limit(80)
        .filter_map { |chat| ChatCandidate.for(chat) }
        .first(40)
    end

    def worker_candidates
      WorkerCandidate.all
    end

    class Candidate
      def matches?(query)
        search_text.include?(query)
      end

      def sort_key
        [ section_order, -score, -timestamp.to_i, key ]
      end

      def as_json
        {
          key: key,
          id: id,
          kind: kind,
          section: section,
          section_title: section_title,
          label: label,
          secondary_text: secondary_text,
          working_directory: working_directory,
          state: state,
          actionability: actionability,
          workflow_id: workflow_id,
          chat_session_id: chat_session_id,
          worker_hostname: worker_hostname,
          worker_storage_key: worker_storage_key,
          queue_name: queue_name,
          available: available,
          disabled_reason: disabled_reason,
          default_visible: default_visible?,
          search_text: search_text
        }.compact
      end

      def id = nil
      def state = nil
      def actionability = nil
      def workflow_id = nil
      def chat_session_id = nil
      def worker_hostname = nil
      def worker_storage_key = nil
      def queue_name = nil
      def available = nil
      def disabled_reason = nil
      def timestamp = Time.at(0)
      def default_visible? = true

      private

      def repository_label(repository)
        return nil unless repository

        [ repository.owner, repository.name ].compact_blank.join("/")
      end
    end

    class WorkflowCandidate < Candidate
      ACTIONABLE_JOB_STATES = %w[failed running implemented approved landing coding].freeze
      ACTIONABLE_WORKFLOW_STATES = %w[failed running queued].freeze

      def initialize(workflow, queue_name:)
        @workflow = workflow
        @queue_name = queue_name
      end

      def key = "workflow:#{@workflow.id}"
      def id = @workflow.id
      def kind = "workflow"
      def section = "interesting_workflows"
      def section_title = "Interesting workflows"
      def section_order = 0
      def workflow_id = @workflow.id
      def state = @workflow.state
      def timestamp = @workflow.updated_at || @workflow.created_at
      def working_directory = availability.working_directory
      def worker_hostname = @workflow.worker_hostname.presence
      def worker_storage_key = @workflow.worker_storage_key.presence
      def available = availability.available?
      def disabled_reason = availability.reason

      def queue_name = availability.queue_name.presence || @queue_name

      def label
        "#{@workflow.slug} - #{@workflow.job.title}"
      end

      def secondary_text
        [
          repository_label(@workflow.job.repository),
          @workflow.job.slug,
          @workflow.trigger_kind,
          @workflow.state,
          worker_context,
          cleaned_up_context
        ].compact_blank.join(" · ")
      end

      def actionability
        return "workspace cleaned up" if @workflow.cleaned_up_at.present?
        return "needs attention" if @workflow.failed?
        return "running" if @workflow.running? || @workflow.queued?
        return "ready job" if ACTIONABLE_JOB_STATES.include?(@workflow.job.state)

        "recent"
      end

      def default_visible?
        return false if @workflow.cleaned_up_at.present?
        return true if ACTIONABLE_WORKFLOW_STATES.include?(@workflow.state)
        return true if ACTIONABLE_JOB_STATES.include?(@workflow.job.state)

        !(@workflow.succeeded? || @workflow.cancelled?)
      end

      def score
        score = 0
        score += 80 if ACTIONABLE_WORKFLOW_STATES.include?(@workflow.state)
        score += 40 if ACTIONABLE_JOB_STATES.include?(@workflow.job.state)
        score += 20 if @workflow.cleaned_up_at.blank?
        score -= 100 if @workflow.cleaned_up_at.present?
        score -= 50 if @workflow.succeeded? || @workflow.cancelled?
        score
      end

      def search_text
        [
          key,
          @workflow.slug,
          @workflow.job.slug,
          @workflow.job.title,
          @workflow.job.issue_title,
          repository_label(@workflow.job.repository),
          @workflow.state,
          @workflow.job.state,
          @workflow.trigger_kind,
          worker_hostname,
          worker_storage_key,
          queue_name,
          disabled_reason,
          working_directory
        ].compact_blank.join(" ").downcase
      end

      private

      def availability
        @availability ||= Terminal::WorkspaceAvailability.for(@workflow)
      end

      def worker_context
        return if worker_hostname.blank? && worker_storage_key.blank?

        [ worker_hostname, worker_storage_key ].compact_blank.join(" / ")
      end

      def cleaned_up_context
        "cleaned up" if @workflow.cleaned_up_at.present?
      end
    end

    class WorkflowQueueNames
      def initialize(workflows)
        @workflows = workflows
      end

      def to_h
        @workflows.to_h { |workflow| [ workflow.id, queue_name_for(workflow) ] }
      end

      private

      def queue_name_for(workflow)
        storage_key = workflow.worker_storage_key.presence
        if storage_key
          queue_name = Workflow.resume_queue_name(storage_key)
          return queue_name if live_resume_queues.include?(queue_name)

          return nil
        end

        host = workflow.worker_hostname.presence
        return nil unless host
        return nil unless live_worker_hosts.include?(host)

        Workflow.resume_queue_name(host)
      end

      def live_resume_queues
        @live_resume_queues ||= WorkerCandidate.live_resume_queues_by_hostname.values.flatten.to_set
      end

      def live_worker_hosts
        @live_worker_hosts ||= InstanceVersion.fresh.where(role: "worker").pluck(:hostname).to_set
      rescue ActiveRecord::StatementInvalid
        Set.new
      end
    end

    class ChatCandidate < Candidate
      def self.for(chat)
        working_directory = ChatWorkspace.path_for(chat)
        return nil unless working_directory.directory?

        new(chat, working_directory:)
      end

      def initialize(chat, working_directory:)
        @chat = chat
        @working_directory = working_directory
      end

      def key = "chat:#{@chat.id}"
      def id = @chat.id
      def kind = "chat"
      def section = "coding_chats"
      def section_title = "Coding chats"
      def section_order = 1
      def chat_session_id = @chat.id
      def timestamp = @chat.last_message_at || @chat.updated_at || @chat.created_at
      def working_directory = @working_directory.to_s
      def state = @chat.mode
      def queue_name = "chat"

      def label
        title = @chat.title.presence || ChatSession.fallback_title_for(repository) || "Chat ##{@chat.id}"
        "Chat ##{@chat.id} - #{title}"
      end

      def secondary_text
        [
          repository_label(repository),
          @chat.mode&.titleize,
          @chat.coding_checkout_branch,
          @chat.workspace_path.presence || working_directory
        ].compact_blank.join(" · ")
      end

      def actionability
        return "coding checkout retained" if @chat.coding? && @chat.coding_checkout_branch.present?
        return "workspace retained" if @chat.workspace_path.present?
        return @chat.mode if @chat.mode.present?

        "recent chat"
      end

      def score
        score = 0
        score += 80 if @chat.coding?
        score += 40 if @chat.workspace_path.present?
        score += 30 if @chat.coding_checkout_branch.present?
        score += 10 if repository.present?
        score
      end

      def search_text
        [
          key,
          "chat-#{@chat.id}",
          "chat ##{@chat.id}",
          @chat.title,
          @chat.mode,
          @chat.coding_checkout_branch,
          repository_label(repository),
          working_directory
        ].compact_blank.join(" ").downcase
      end

      private

      def repository
        @repository ||= @chat.repository
      end
    end

    class WorkerCandidate < Candidate
      def self.all
        instances = live_worker_instances.to_a
        instances = [ fallback_instance ] if instances.empty?

        instances.flat_map do |instance|
          queues_for(instance).map { |queue| new(instance, queue) }
        end
      rescue NameError, ActiveRecord::StatementInvalid
        [ new(fallback_instance, nil) ]
      end

      def self.live_worker_instances
        InstanceVersion.fresh.where(role: "worker").order(:hostname)
      end

      def self.fallback_instance
        Struct.new(:hostname, :data_root_path, :last_heartbeat_at, :started_at)
          .new(SyrusVersion.hostname, WorkerStorageIdentity.default_data_root.to_s, Time.current, Time.current)
      end

      def self.queues_for(instance)
        queues = live_resume_queues_by_hostname.fetch(instance.hostname, [])
        queues.presence || [ nil ]
      end

      def self.live_resume_queues_by_hostname
        SolidQueue::Process.where.not(last_heartbeat_at: nil).each_with_object({}) do |process, memo|
          next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago

          resume_queues = InstanceVersion.queue_names(process.metadata&.dig("queues")).select { |queue| queue.start_with?("resume-") }
          next if resume_queues.empty?

          memo[process.hostname] ||= []
          memo[process.hostname].concat(resume_queues)
          memo[process.hostname].uniq!
        end
      rescue NameError, ActiveRecord::StatementInvalid
        {}
      end

      def initialize(instance, queue_name)
        @instance = instance
        @queue_name = queue_name
      end

      def key
        queue_name.present? ? "worker:#{@instance.hostname}:#{worker_storage_key}" : "worker:#{@instance.hostname}"
      end

      def id = key
      def kind = "worker"
      def section = "workers"
      def section_title = "Workers"
      def section_order = 2
      def timestamp = @instance.last_heartbeat_at || @instance.started_at
      def worker_hostname = @instance.hostname
      def worker_storage_key = queue_name&.delete_prefix("resume-")
      def queue_name = @queue_name.presence || "chat"
      def working_directory = Rails.root.to_s
      def state = "live"
      def actionability = worker_storage_key.present? ? "storage-affinity scratch" : "live worker"
      def score = worker_storage_key.present? ? 40 : 10

      def label
        worker_storage_key.present? ? "Scratch on #{@instance.hostname}" : "Scratch on #{@instance.hostname} (best effort)"
      end

      def secondary_text
        [
          @instance.data_root_path,
          worker_storage_key,
          queue_name
        ].compact_blank.join(" · ")
      end

      def search_text
        [
          key,
          label,
          @instance.hostname,
          @instance.data_root_path,
          worker_storage_key,
          queue_name
        ].compact_blank.join(" ").downcase
      end
    end
  end
end
