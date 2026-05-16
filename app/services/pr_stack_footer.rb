class PrStackFooter
  START_MARKER = "<!-- syrus-stack:start -->".freeze
  END_MARKER = "<!-- syrus-stack:end -->".freeze

  def self.apply(body, job)
    new(job).apply(body)
  end

  def self.refresh!(job, client: nil)
    new(job, client: client).refresh!
  end

  def initialize(job, client: nil)
    @job = job
    @client = client
  end

  def apply(body)
    stripped = strip_existing(body.to_s.rstrip)
    return stripped unless stacked?

    [ stripped, "", START_MARKER, sentence, END_MARKER ].join("\n")
  end

  def refresh!
    return if @job.pr_number.blank?

    pr = client.pull_request(@job.repository.slug, @job.pr_number, bypass_cache: true)
    body = apply(pr.body.to_s)
    client.update_pull_request_body(@job.repository.slug, @job.pr_number, body)
  end

  def sentence
    "**Stack:** #{stack_jobs.map { |stack_job| segment(stack_job) }.join(' → ')}"
  end

  private

  def strip_existing(body)
    body.gsub(/\n*#{Regexp.escape(START_MARKER)}.*?#{Regexp.escape(END_MARKER)}\s*/m, "").rstrip
  end

  def stacked?
    @job.parent_job.present? || @job.stack_children.exists?
  end

  def stack_jobs
    ancestors + [ @job ] + descendants
  end

  def ancestors
    chain = []
    cursor = @job.parent_job
    while cursor
      chain.unshift(cursor)
      cursor = cursor.parent_job
    end
    chain
  end

  def descendants
    chain = []
    cursor = @job
    while (child = cursor.stack_children.where.not(pr_number: nil).order(:id).first)
      chain << child
      cursor = child
    end
    chain
  end

  def segment(stack_job)
    url = pull_request_url(stack_job)
    if stack_job.id == @job.id
      url ? "**[this](#{url})**" : "**this**"
    elsif url
      "[##{stack_job.pr_number}](#{url})"
    else
      "##{stack_job.id}"
    end
  end

  def pull_request_url(stack_job)
    return if stack_job.pr_number.blank?

    "https://github.com/#{stack_job.repository.slug}/pull/#{stack_job.pr_number}"
  end

  def client
    @client ||= GithubClient.for(repository: @job.repository, user: @job.user)
  end
end
