class PrCostFooter
  START_MARKER = "<!-- syrus-cost-footer:start -->".freeze
  END_MARKER = "<!-- syrus-cost-footer:end -->".freeze

  def self.apply(body, job)
    new(job).apply(body)
  end

  def initialize(job)
    @job = job
  end

  def apply(body)
    stripped = strip_existing(body.to_s.rstrip)
    return stripped unless @job.repository.pr_cost_footer_enabled?

    parts = [ sentence ]
    parts << backlinks if backlinks.present?
    [ stripped, "", START_MARKER, *parts, END_MARKER ].join("\n")
  end

  def sentence
    "This PR was implemented by Syrus across #{runs_label} at a total cost of #{formatted_cost}."
  end

  private

  def backlinks
    return nil if host.blank?

    links = []
    if (epic = @job.epic)
      links << "[#{App::Presentation.epic_slug(epic)}](#{host}/epics/#{epic.number})"
    end
    links << "[#{App::Presentation.job_slug(@job)}](#{host}/jobs/#{@job.id})"
    links.join(" / ")
  end

  def host
    @host ||= ENV["SYRUS_APP_HOST"].to_s.sub(%r{/\z}, "")
  end

  def strip_existing(body)
    body.gsub(/\n*#{Regexp.escape(START_MARKER)}.*?#{Regexp.escape(END_MARKER)}\s*/m, "").rstrip
  end

  def runs_label
    count = @job.runs.count
    "#{count} #{'Run'.pluralize(count)}"
  end

  def formatted_cost
    format("$%.2f", @job.total_cost_usd.to_d)
  end
end
