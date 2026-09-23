# Scrubbed subprocess env for a Coding Mode chat workspace -- shared by
# ChatWorkspacePrepareJob (dependency install) and
# ChatShellCommandExecutor::Coding (ad hoc `!` commands), both of which run
# against the same persistent per-ChatSession checkout and need the same
# base env plus whatever :step_environment plugin providers (e.g.
# BuildCache::StepEnvironment) contribute for this chat session's
# PrepareScope -- the same extension point Steps::Prepare/Steps::Grader use
# for workflow Steps, so a compiler cache (or any future :step_environment
# plugin) is configured consistently across both surfaces.
module ChatWorkspaceEnv
  def self.for(chat_session:, repository:, workspace_path:)
    scope = PrepareScope.for_chat_session(chat_session, repository: repository)
    extra = Steps::Prepare.prep_extra_env(scope: scope, workspace_path: workspace_path)
    ProcessRunner.forwarded_env(Steps::Prepare.prep_env_forward, extra: extra)
  end
end
