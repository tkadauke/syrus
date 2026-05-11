class IngestPolicy
  SKIP_LABEL = "syrus-skip".freeze

  Result = Data.define(:allow, :reason)

  def self.evaluate(issue, repository, bot_login: nil, trigger_config: RepoTriggerConfig.new, comments: [])
    new(issue, repository, bot_login: bot_login, trigger_config: trigger_config, comments: comments).evaluate
  end

  def initialize(issue, repository, bot_login:, trigger_config:, comments:)
    @issue = issue
    @repository = repository
    @bot_login = bot_login.to_s
    @trigger_config = trigger_config
    @comments = comments
  end

  def evaluate
    return deny("is a pull request") if pull_request?
    return deny("is closed") if closed?
    return deny("opted out via #{SKIP_LABEL}") if opted_out?
    return allow if trigger_label_present?
    return allow if mention_trigger_present?
    return allow if assignment_trigger_present?

    if @bot_login.present?
      deny("missing trigger label #{@repository.trigger_label.inspect}, @#{@bot_login} mention, or assignment to #{@bot_login}")
    else
      deny("missing trigger label #{@repository.trigger_label.inspect}")
    end
  end

  def needs_comments?
    @trigger_config.mentions? &&
      !trigger_label_present? &&
      !issue_body_mentions_bot? &&
      !assignment_trigger_present? &&
      !comments_count_known_zero?
  end

  def with_comments(comments)
    self.class.new(@issue, @repository, bot_login: @bot_login, trigger_config: @trigger_config, comments: comments)
  end

  private

  def pull_request?
    @issue.respond_to?(:pull_request) && @issue.pull_request.present?
  end

  def closed?
    @issue.state.to_s == "closed"
  end

  def label_names
    Workflows.label_names(@issue.labels)
  end

  def opted_out?
    label_names.include?(SKIP_LABEL)
  end

  def trigger_label_present?
    label_names.include?(@repository.trigger_label)
  end

  def mention_trigger_present?
    return false unless @trigger_config.mentions?
    return false if @bot_login.blank?

    issue_body_mentions_bot? || @comments.any? { |comment| mentions_bot?(body_text(comment)) }
  end

  def issue_body_mentions_bot?
    mentions_bot?(body_text(@issue))
  end

  def assignment_trigger_present?
    return false unless @trigger_config.assignments?
    return false if @bot_login.blank?

    return false unless @issue.respond_to?(:assignees)

    Array(@issue.assignees).any? do |assignee|
      login = assignee_login(assignee)
      login.casecmp?(@bot_login)
    end
  end

  def assignee_login(assignee)
    if assignee.respond_to?(:login)
      assignee.login
    elsif assignee.respond_to?(:[])
      assignee[:login] || assignee["login"]
    else
      assignee.to_s
    end
  end

  def comments_count_known_zero?
    @issue.respond_to?(:comments) && !@issue.comments.nil? && @issue.comments.to_i.zero?
  end

  def body_text(object)
    object.respond_to?(:body) ? object.body.to_s : ""
  end

  def mentions_bot?(text)
    return false if text.blank?

    text.match?(/(?<![A-Za-z0-9_])@#{Regexp.escape(@bot_login)}(?![A-Za-z0-9_-])/i)
  end

  def allow
    Result.new(allow: true, reason: nil)
  end

  def deny(reason)
    Result.new(allow: false, reason: reason)
  end
end
