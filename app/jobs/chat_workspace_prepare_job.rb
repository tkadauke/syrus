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
    mark_prepare_running!(chat_session)

    path = ChatWorkspace.repo_path_for(chat_session, repository)
    unless path.join(".git").directory?
      Rails.logger.info("[ChatWorkspacePrepareJob] checkout not found at #{path}; skipping")
      mark_prepare_failed!(chat_session, "checkout not found at #{path}")
      return
    end

    plan = RepoPrepPlan.for(path)

    Rails.logger.info("[ChatWorkspacePrepareJob] chat=#{chat_session_id} repo=#{repository.slug} source=#{plan.source}")
    Rails.logger.info("[ChatWorkspacePrepareJob] note: #{plan.note}") if plan.note

    if plan.commands.empty?
      Rails.logger.info("[ChatWorkspacePrepareJob] no commands to run; skipping")
      mark_prepare_succeeded!(chat_session)
      return
    end

    plan.commands.each_with_index do |cmd, i|
      Rails.logger.info("[ChatWorkspacePrepareJob] (#{i + 1}/#{plan.commands.size}) $ #{cmd}")
      success = run_prep_command(cmd, path)
      next if success

      if plan.guessed?
        Rails.logger.warn("[ChatWorkspacePrepareJob] guessed setup command failed — workspace will work but may need manual setup")
        mark_prepare_failed!(chat_session, "guessed setup command failed: #{cmd}")
      else
        Rails.logger.error("[ChatWorkspacePrepareJob] explicit .syrus.yml command failed — workspace may be unprepared")
        mark_prepare_failed!(chat_session, "explicit .syrus.yml command failed: #{cmd}")
      end
      return
    end

    Rails.logger.info("[ChatWorkspacePrepareJob] all commands completed successfully")
    mark_prepare_succeeded!(chat_session)
  rescue StandardError => e
    mark_prepare_failed!(chat_session, "#{e.class}: #{e.message}") if defined?(chat_session) && chat_session
    raise
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

  def mark_prepare_running!(chat_session)
    chat_session.update_columns(
      coding_checkout_prepare_status: "running",
      coding_checkout_prepare_started_at: Time.current,
      coding_checkout_prepare_finished_at: nil,
      coding_checkout_prepare_failure: nil,
      updated_at: Time.current
    )
  end

  def mark_prepare_succeeded!(chat_session)
    chat_session.update_columns(
      coding_checkout_prepare_status: "succeeded",
      coding_checkout_prepare_finished_at: Time.current,
      coding_checkout_prepare_failure: nil,
      updated_at: Time.current
    )
  end

  def mark_prepare_failed!(chat_session, message)
    chat_session.update_columns(
      coding_checkout_prepare_status: "failed",
      coding_checkout_prepare_finished_at: Time.current,
      coding_checkout_prepare_failure: message.to_s.truncate(2_000),
      updated_at: Time.current
    )
  end
end
