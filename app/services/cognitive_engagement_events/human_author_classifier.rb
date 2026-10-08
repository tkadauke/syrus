module CognitiveEngagementEvents
  class HumanAuthorClassifier
    BOT_EMAIL_PATTERN = /\A.+\[bot\]@users\.noreply\.github\.com\z/i.freeze
    BOT_NAME_PATTERN = /\[bot\]\z/i.freeze
    GITHUB_NOREPLY_PATTERN = /\A(?:\d+\+)?(?<handle>[^@]+)@users\.noreply\.github\.com\z/i.freeze

    def initialize(repository)
      @agent_commit_shas = agent_commit_scope(repository).pluck(:sha).to_set
    end

    def user_for(commit)
      return nil if agent_authored?(commit)

      user_by_email(commit.author_email) ||
        user_by_github_handle(commit.author_email) ||
        user_by_github_handle(commit.author_name)
    end

    private

    attr_reader :agent_commit_shas

    def agent_commit_scope(repository)
      LandedCommit.where(landable: repository.jobs)
        .or(LandedCommit.where(landable: repository.epics))
        .or(LandedCommit.where(landable: MergeTrain.where(repository: repository)))
    end

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
