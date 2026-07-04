class Job::GithubReviewApprovalSyncer
  def self.sync(job:, reviews:)
    new(job).sync(reviews)
  end

  def initialize(job)
    @job = job
  end

  # Creates JobApproval records for each GitHub review with state "APPROVED"
  # where the reviewer maps to a Syrus user. Skips dismissed reviews (they
  # show state "DISMISSED", not "APPROVED") and records that already exist.
  def sync(reviews)
    Array(reviews).each do |review|
      next unless review.state == "APPROVED"

      github_login = review.user&.login
      next if github_login.blank?

      user = User.find_by(github_handle: github_login)
      next unless user

      next if @job.job_approvals.where(user: user).exists?

      @job.job_approvals.create!(
        user: user,
        approved_at: parse_submitted_at(review) || Time.current
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # Another concurrent poller created the record between exists? and create!
    end
  end

  private

  def parse_submitted_at(review)
    value = review.respond_to?(:submitted_at) ? review.submitted_at : nil
    return value if value.respond_to?(:to_time) && !value.is_a?(String)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
