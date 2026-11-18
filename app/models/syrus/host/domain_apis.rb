module Syrus
  module Host
    module DomainApis
    end

    class Job < ReadFacade
      wraps ::Job

      class << self
        def visible_to(user) = wrap_all(record_class.visible_to(user))
        alias accessible_to visible_to
      end

      def id = read(:id)
      def state = read(:state)
      def title = read(:title)
      def repository = Repository.wrap(read(:repository))
      def user = User.wrap(read(:user))
      def workflows = Workflow.wrap_all(read(:workflows))
    end

    class Repository < ReadFacade
      wraps ::Repository

      class << self
        def active = wrap_all(record_class.active)
        def accessible_to(user) = wrap_all(record_class.where(id: record_class.accessible_repository_ids_for(user)))
        def writable_by(user) = wrap_all(record_class.writable_by(user))
      end

      def id = read(:id)
      def owner = read(:owner)
      def name = read(:name)
      def archived_at = read(:archived_at)
      def jobs = Job.wrap_all(read(:jobs))
    end

    class User < ReadFacade
      wraps ::User

      def id = read(:id)
      def handle = read(:handle)
      def display_name = read(:display_name)
      def admin? = read(:admin?)
      def repositories = Repository.wrap_all(read(:repositories))
      def jobs = Job.wrap_all(read(:jobs))
    end

    class Run < ReadFacade
      wraps ::Run

      def id = read(:id)
      def state = read(:state)
      def workflow = Workflow.wrap(read(:workflow))
      def job = Job.wrap(read(:job))
    end

    class Workflow < ReadFacade
      wraps ::Workflow

      def id = read(:id)
      def state = read(:state)
      def job = Job.wrap(read(:job))
      def runs = Run.wrap_all(read(:runs))
    end

    class ChatSession < ReadFacade
      wraps ::ChatSession

      def id = read(:id)
      def title = read(:title)
      def user = User.wrap(read(:user))
      def repository = Repository.wrap(read(:repository))
    end
  end
end

{
  Job: [ "Reads a job's identity, state, title, repository, owner, and workflows through find and visibility-scoped lookups; transitions, persistence, callbacks, and other associations are not promised.", %w[find visible_to accessible_to id state title repository user workflows] ],
  Repository: [ "Reads repository identity, owner/name, archival state, and jobs through find and access-scoped lookups; credentials, synchronization, persistence, and other associations are not promised.", %w[find active accessible_to writable_by id owner name archived_at jobs] ],
  User: [ "Reads user identity, handle, display name, administrator status, repositories, and jobs through find; credentials, preferences, persistence, and other associations are not promised.", %w[find id handle display_name admin? repositories jobs] ],
  Run: [ "Reads a run's identity, state, workflow, and job through find; dispatch, lifecycle transitions, persistence, and other associations are not promised.", %w[find id state workflow job] ],
  Workflow: [ "Reads a workflow's identity, state, job, and runs through find; scheduling, transitions, repair, persistence, and other associations are not promised.", %w[find id state job runs] ],
  ChatSession: [ "Reads a chat session's identity, title, owner, and repository through find; turns, broadcasts, artifacts, persistence, and other associations are not promised.", %w[find id title user repository] ]
}.each do |name, (summary, members)|
  Syrus::Host.api("Syrus::Host::#{name}", since: "0.1.16", summary:, members:)
end
