class JobMetadataRefreshApplier
  def initialize(workflow, client: nil)
    @workflow = workflow
    @job = workflow.job
    @client = client
  end

  def call
    metadata = @workflow.artifact("job_metadata")
    return unless metadata.is_a?(Hash)

    before = before_snapshot
    return record_noop!(metadata, before) unless metadata["changed"] == true

    update_direct_job_title(metadata)
    update_pull_request(metadata)
    IndexJobSearchJob.perform_later(@job.id)
    record_applied!(metadata, before)
    "applied refreshed Job metadata"
  end

  private

  def record_noop!(metadata, before)
    @workflow.set_artifact!("job_metadata_applied", {
      "changed" => false,
      "before" => before,
      "applied_at" => Time.current.iso8601,
      "reason" => metadata["intent_revision_reason"].presence
    }.compact)
    "metadata refresh made no canonical changes"
  end

  def update_direct_job_title(metadata)
    return unless @job.direct?
    return if metadata["title"].blank?
    return if @job.issue_title == metadata["title"]

    @job.update!(issue_title: metadata["title"])
  end

  def update_pull_request(metadata)
    return if @job.pr_number.blank?

    title = metadata["title"].presence
    body = compose_pr_body(metadata)
    client.update_pull_request_metadata(@job.effective_pr_repository.slug, @job.pr_number, title: title, body: body)
  end

  def compose_pr_body(metadata)
    body = metadata["pr_body"].to_s.rstrip
    parts = []
    parts << "Closes ##{@job.issue_number}" if @job.issue?
    parts << "" if @job.issue?
    parts << body
    if (testing = testing_section(metadata["test_plan"])).present?
      parts << ""
      parts << testing
    end
    if @job.direct? && (handle = BotIdentity.github_handle(@job.user))
      parts << ""
      parts << "Triggered by @#{handle}"
    end
    parts << ""
    parts << "---"
    parts << attribution_footer
    PrCostFooter.apply(PrStackFooter.apply(parts.join("\n"), @job), @job)
  end

  def testing_section(test_plan)
    return unless test_plan.is_a?(Hash)

    steps = Array(test_plan["steps"]).map(&:to_s).map(&:strip).reject(&:empty?)
    notes = test_plan["notes"].to_s.strip
    return if steps.empty? && notes.blank?

    lines = [ "## Test Plan", "", "```sh", "syrus checkout #{@job.slug}", "```", "" ]
    steps.each { |step| lines << "- #{step}" }
    if notes.present?
      lines << ""
      lines << notes
    end
    lines.join("\n")
  end

  def attribution_footer
    provider = @workflow.agent_provider.presence
    author = provider.present? ? provider.titleize : "an LLM"
    "*Authored by #{author} (trigger=#{@workflow.trigger_kind}). Review carefully.*"
  end

  def before_snapshot
    pr = current_pr
    {
      "job_title" => @job.title,
      "pr_title" => pr&.title,
      "pr_body" => pr&.body
    }.compact
  end

  def record_applied!(metadata, before)
    @workflow.set_artifact!("job_metadata_applied", {
      "changed" => true,
      "before" => before,
      "after" => metadata.slice("title", "summary", "pr_body", "test_plan", "intent_revision_reason"),
      "applied_at" => Time.current.iso8601
    })
  end

  def current_pr
    return if @job.pr_number.blank?

    @current_pr ||= client.pull_request(@job.effective_pr_repository.slug, @job.pr_number, bypass_cache: true)
  end

  def client
    @client ||= GithubClient.for(repository: @job.effective_pr_repository, user: @job.user)
  end
end
