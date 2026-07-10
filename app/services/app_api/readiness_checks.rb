module AppApi
  class ReadinessChecks
    Check = Data.define(:key, :label, :status, :message, :remediation, :optional)

    TOKEN_PATTERNS = [
      %r{(https://x-access-token:)[^@\s]+(@)}i,
      /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/,
      /\bsk-[A-Za-z0-9_-]{20,}\b/,
      /\b(?:oat|claude|codex)[-_][A-Za-z0-9_-]{12,}\b/i
    ].freeze

    # Grace window covering several SyncInstallationsJob ticks (every 5
    # minutes) after GitHub App registration, during which missing
    # installations read as "sync pending" rather than misconfiguration.
    INSTALLATION_SYNC_GRACE = 15.minutes

    def initialize(user)
      @user = user
    end

    def as_json(*)
      checks = [
        web_config_check,
        worker_queue_check,
        pause_check,
        storage_check,
        github_check,
        agent_provider_check,
        github_app_check
      ].compact

      {
        status: overall_status(checks),
        checks: checks.map { |check| serialize_check(check) }
      }
    end

    private

    attr_reader :user

    def web_config_check
      ActiveRecord::Base.connection.active?
      if Rails.env.production? && !active_record_encryption_ready?
        return check(
          "web_config",
          "Web/config",
          "error",
          "Rails is running, but Active Record encryption is not configured in the web environment.",
          "Set RAILS_MASTER_KEY or provide ACTIVE_RECORD_ENCRYPTION_* environment variables on every web and worker process."
        )
      end

      check("web_config", "Web/config", "ok", "Rails booted and the primary database connection is available.", nil)
    rescue => e
      check(
        "web_config",
        "Web/config",
        "error",
        "The web process cannot reach the primary database: #{safe_error(e)}.",
        "Verify DB_HOST, SYRUS_DATABASE_PASSWORD, database migrations, and network access from the web pod."
      )
    end

    def active_record_encryption_ready?
      plaintext = "syrus-readiness-probe"
      ciphertext = ActiveRecord::Encryption.encryptor.encrypt(plaintext)
      ActiveRecord::Encryption.encryptor.decrypt(ciphertext) == plaintext
    rescue StandardError
      false
    end

    def worker_queue_check
      worker_count = SolidQueue::Process.where(kind: "Worker").count
      return check("worker_queue", "Worker/queue", "ok", "#{worker_count} Solid Queue worker process#{'es' unless worker_count == 1} registered.", nil) if worker_count.positive?

      check(
        "worker_queue",
        "Worker/queue",
        "error",
        "No Solid Queue worker processes are registered.",
        "Start the worker process with bin/jobs and confirm it can connect to the queue database."
      )
    rescue => e
      check(
        "worker_queue",
        "Worker/queue",
        "error",
        "Solid Queue tables are not reachable from the web process: #{safe_error(e)}.",
        "Run queue database migrations and verify the queue database configuration for web and worker processes."
      )
    end

    def pause_check
      settings = AppSetting.current
      if settings.runs_paused?
        return check(
          "polling_runs",
          "Polling/runs",
          "error",
          "Agent runs are paused.",
          "Resume runs from the admin console before expecting Syrus to start work."
        )
      end

      if settings.polling_paused?
        return check(
          "polling_runs",
          "Polling/runs",
          "warning",
          "Repository polling is paused; direct jobs can run, but labeled GitHub issues will not be picked up.",
          "Resume polling from the admin console when issue delegation should be active."
        )
      end

      check("polling_runs", "Polling/runs", "ok", "Polling and agent runs are enabled.", nil)
    end

    def storage_check
      root = WorkflowWorkspace.data_root
      FileUtils.mkdir_p(root)
      probe = root.join(".readiness-#{SecureRandom.hex(8)}")
      probe.write("ok")
      probe.delete
      check("storage", "Storage", "ok", "SYRUS_DATA_ROOT is writable.", nil)
    rescue => e
      check(
        "storage",
        "Storage",
        "error",
        "Syrus cannot write to SYRUS_DATA_ROOT: #{safe_error(e)}.",
        "Mount a writable persistent volume at SYRUS_DATA_ROOT and ensure the Rails user owns it."
      )
    ensure
      FileUtils.rm_f(probe) if defined?(probe) && probe
    end

    def github_check
      if user.github_token.present?
        GithubClient.for_user(user).readiness_check!
        return check("github", "GitHub", "ok", "GitHub accepted the configured personal access token.", nil)
      end

      if AppSetting.github_app_registered?
        return check("github", "GitHub", "ok", "GitHub App credentials are registered; repository installations are checked separately.", nil)
      end

      check(
        "github",
        "GitHub",
        "error",
        "No GitHub personal access token or GitHub App registration is configured.",
        "Add a GitHub token in credentials or register a GitHub App from the admin GitHub App page."
      )
    rescue Octokit::Unauthorized, Octokit::Forbidden
      check(
        "github",
        "GitHub",
        "error",
        "GitHub rejected the configured credentials.",
        "Rotate the GitHub token or reinstall the GitHub App with repository access."
      )
    rescue Octokit::TooManyRequests
      check(
        "github",
        "GitHub",
        "warning",
        "GitHub API rate limits are currently exhausted.",
        "Wait for the rate-limit reset or use credentials with a higher available quota."
      )
    rescue => e
      check(
        "github",
        "GitHub",
        "error",
        "GitHub could not be reached: #{safe_error(e)}.",
        "Check outbound network access to api.github.com and verify the configured GitHub credentials."
      )
    end

    def agent_provider_check
      provider = user.agent_provider
      unless User.agent_providers.include?(provider)
        return check(
          "agent_provider",
          "Agent provider",
          "error",
          "The selected agent provider is not recognized.",
          "Choose a supported provider in credentials."
        )
      end

      return check("agent_provider", "Agent provider", "ok", "#{provider_label(provider)} credentials are configured.", nil) if user.agent_provider_configured?(provider)

      check(
        "agent_provider",
        "Agent provider",
        "error",
        "#{provider_label(provider)} is selected but its credentials are missing.",
        "Add #{provider_label(provider)} credentials or choose another configured provider."
      )
    end

    def github_app_check
      settings = AppSetting.current
      return nil unless settings.github_app_registered? || Installation.exists?

      if settings.github_app_private_key_pem.blank?
        return check(
          "github_app",
          "GitHub App",
          "error",
          "A GitHub App id is present, but its private key is missing.",
          "Complete GitHub App registration again from the admin page so installation tokens can be minted.",
          optional: true
        )
      end

      active_count = Installation.active.count
      return check("github_app", "GitHub App", "ok", "#{active_count} active GitHub App installation#{'s' unless active_count == 1} linked.", nil, optional: true) if active_count.positive?

      # No active installations, but the remediation copy itself says a PAT is
      # an acceptable alternative — so this optional check passes when the
      # PATs GithubClient.for would ACTUALLY fall back to are in place (see
      # personal_access_token_configured?), instead of warning on every fresh
      # PAT-based install.
      if personal_access_token_configured?
        return check(
          "github_app",
          "GitHub App",
          "ok",
          "No active GitHub App installations are linked yet; repositories fall back to a configured personal access token.",
          nil,
          optional: true
        )
      end

      # Installations sync asynchronously (SyncInstallationsJob runs right
      # after registration and every 5 minutes). A just-registered App with no
      # synced installation rows is pending, not misconfigured.
      if github_app_recently_registered?(settings)
        return check(
          "github_app",
          "GitHub App",
          "ok",
          "GitHub App registered recently; the first installation sync may not have completed yet.",
          nil,
          optional: true
        )
      end

      check(
        "github_app",
        "GitHub App",
        "warning",
        "GitHub App credentials exist, but no active installations are linked.",
        "Install the GitHub App on at least one GitHub owner, or use a personal access token.",
        optional: true
      )
    end

    def github_app_recently_registered?(settings)
      registered_at = settings.github_app_registered_at
      registered_at.present? && registered_at > INSTALLATION_SYNC_GRACE.ago
    end

    def personal_access_token_configured?
      # The PAT fallback in GithubClient.for authenticates as `user ||
      # repository.user`, and the polling/ingestion paths pass the repository's
      # owning user — so once repositories exist, only the OWNERS' PATs would
      # actually be used. The honest rule: every active repository's owner must
      # have a PAT (an owner without one has no working credential path at all
      # while no installation is linked). Before any repository exists, any
      # user's PAT is acceptable — the first repository will be attached to
      # whichever user configured it.
      #
      # Encrypted column: NULL rows never had a token; decrypt only the
      # candidates to skip blank-but-encrypted leftovers.
      owner_ids = Repository.active.distinct.pluck(:user_id)
      if owner_ids.any?
        return false if owner_ids.include?(nil)

        User.where(id: owner_ids).all? { |owner| owner.github_token.present? }
      else
        User.where.not(github_token: nil).any? { |candidate| candidate.github_token.present? }
      end
    end

    def provider_label(provider)
      App::Presentation.agent_provider_label(provider)
    end

    def overall_status(checks)
      return "error" if checks.any? { |check| check.status == "error" }
      return "warning" if checks.any? { |check| check.status == "warning" }

      "ok"
    end

    def serialize_check(check)
      {
        key: check.key,
        label: check.label,
        status: check.status,
        message: check.message,
        remediation: check.remediation,
        optional: check.optional
      }
    end

    def check(key, label, status, message, remediation, optional: false)
      Check.new(key:, label:, status:, message: sanitize(message), remediation: remediation && sanitize(remediation), optional:)
    end

    def safe_error(error)
      "#{error.class.name}: #{sanitize(error.message.presence || 'no details')}"
    end

    def sanitize(value)
      sanitized = value.to_s
      TOKEN_PATTERNS.each do |pattern|
        sanitized = sanitized.gsub(pattern) do
          Regexp.last_match.length == 3 ? "#{Regexp.last_match(1)}[REDACTED]#{Regexp.last_match(2)}" : "[REDACTED]"
        end
      end
      sanitized
    end
  end
end
