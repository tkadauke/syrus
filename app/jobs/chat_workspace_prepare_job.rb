class ChatWorkspacePrepareJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  PER_COMMAND_TIMEOUT = 10.minutes.to_i

  # Same scrubbed environment as Steps::Prepare — prevents the worker
  # pod's bundler/npm config from polluting the target repo's install.
  PREP_ENV_FORWARD = %w[
    HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE TZ HOSTNAME TMPDIR SHELL
    MISE_DATA_DIR
  ].freeze

  def perform(chat_session_id, repository_id)
    chat_session = ChatSession.find(chat_session_id)
    repository = Repository.find(repository_id)

    path = ChatWorkspace.repo_path_for(chat_session, repository)
    unless path.join(".git").directory?
      Rails.logger.info("[ChatWorkspacePrepareJob] checkout not found at #{path}; skipping")
      return
    end

    plan = RepoPrepPlan.for(path)

    Rails.logger.info("[ChatWorkspacePrepareJob] chat=#{chat_session_id} repo=#{repository.slug} source=#{plan.source}")
    Rails.logger.info("[ChatWorkspacePrepareJob] note: #{plan.note}") if plan.note

    if plan.commands.empty?
      Rails.logger.info("[ChatWorkspacePrepareJob] no commands to run; skipping")
      return
    end

    plan.commands.each_with_index do |cmd, i|
      Rails.logger.info("[ChatWorkspacePrepareJob] (#{i + 1}/#{plan.commands.size}) $ #{cmd}")
      success = run_prep_command(cmd, path)
      next if success

      if plan.guessed?
        Rails.logger.warn("[ChatWorkspacePrepareJob] guessed setup command failed — workspace will work but may need manual setup")
      else
        Rails.logger.error("[ChatWorkspacePrepareJob] explicit .syrus.yml command failed — workspace may be unprepared")
      end
      return
    end

    Rails.logger.info("[ChatWorkspacePrepareJob] all commands completed successfully")
  end

  private

  def run_prep_command(cmd, path)
    env = ProcessRunner.forwarded_env(PREP_ENV_FORWARD)
    result = ProcessRunner.new(
      env: env,
      command: [ "bash", "-c", cmd ],
      chdir: path,
      timeout: PER_COMMAND_TIMEOUT,
      kind: "chat_prepare"
    ).run
    result.success?
  rescue StandardError => e
    Rails.logger.error("[ChatWorkspacePrepareJob] command raised #{e.class}: #{e.message}")
    false
  end
end
