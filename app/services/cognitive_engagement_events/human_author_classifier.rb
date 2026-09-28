module CognitiveEngagementEvents
  class HumanAuthorClassifier
    BOT_EMAIL_PATTERN = /\A.+\[bot\]@users\.noreply\.github\.com\z/i.freeze
    BOT_NAME_PATTERN = /\[bot\]\z/i.freeze
    GITHUB_NOREPLY_PATTERN = /\A(?:\d+\+)?(?<handle>[^@]+)@users\.noreply\.github\.com\z/i.freeze

    def initialize(repository)
      @repository = repository
      @agent_commit_shas = LandedCommit
        .joins("INNER JOIN jobs ON landed_commits.landable_type = 'Job' AND landed_commits.landable_id = jobs.id")
        .where(jobs: { repository_id: repository.id })
        .pluck(:sha)
        .to_set
    end

    def user_for(commit)
      return nil if agent_authored?(commit)

      user_by_email(commit.author_email) ||
        user_by_github_handle(commit.author_email) ||
        user_by_github_handle(commit.author_name)
    end

    private

    attr_reader :repository, :agent_commit_shas

    def agent_authored?(commit)
      agent_commit_shas.include?(commit.sha) ||
        commit.author_email.to_s.match?(BOT_EMAIL_PATTERN) ||
        commit.author_name.to_s.match?(BOT_NAME_PATTERN) ||
        commit.author_email.to_s.casecmp?(BotIdentity::DEFAULT_EMAIL)
    end

    def user_by_email(email)
      normalized = email.to_s.downcase.strip
      return nil if normalized.blank? || normalized.end_with?("@users.noreply.github.com")

      User.where("LOWER(email_address) = ?", normalized).first
    end

    def user_by_github_handle(value)
      handle = github_handle(value)
      return nil if handle.blank?

      User.where("LOWER(github_handle) = ?", handle.downcase).first
    end

    def github_handle(value)
      text = value.to_s.strip
      return nil if text.blank?

      match = text.match(GITHUB_NOREPLY_PATTERN)
      return match[:handle] if match

      text
    end
  end
end
