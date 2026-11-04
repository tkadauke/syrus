class Coworkers::WorkspaceSaveRetry
  def self.for(operation)
    { "chat_branch" => ChatBranch, "home_branch" => HomeBranch }.fetch(operation).new
  end

  class ChatBranch
    def perform(link)
      Coworkers::ChatWorkspaceLifecycle.new(link.chat_session).finalize!(schedule_background: false)
    end
  end

  class HomeBranch
    def perform(link)
      Coworkers::HomeBranchPersistence.new(link.chat_session, link.coworker).persist!(schedule_background: false)
    end
  end
end
