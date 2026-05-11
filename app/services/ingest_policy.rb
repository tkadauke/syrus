class IngestPolicy
  SKIP_LABEL = "syrus-skip".freeze

  Result = Data.define(:allow, :reason)

  def self.evaluate(issue, repository)
    new(issue, repository).evaluate
  end

  def initialize(issue, repository)
    @issue = issue
    @repository = repository
  end

  def evaluate
    return deny("is a pull request")     if pull_request?
    return deny("is closed")             if closed?
    return deny("opted out via #{SKIP_LABEL}") if opted_out?
    return deny("missing trigger label #{@repository.trigger_label.inspect}") unless trigger_label_present?
    allow
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

  def allow
    Result.new(allow: true, reason: nil)
  end

  def deny(reason)
    Result.new(allow: false, reason: reason)
  end
end
