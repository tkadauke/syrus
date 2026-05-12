class BotIdentity
  DEFAULT_NAME = "Syrus".freeze
  DEFAULT_EMAIL = "syrus@noreply.invalid".freeze

  def self.for(job)
    new(job)
  end

  def self.prefix_comment(body, on_behalf_of: nil)
    return body if on_behalf_of.blank?

    handle = github_handle(on_behalf_of)
    return body if handle.blank?

    "Syrus on behalf of @#{handle}\n\n#{body}"
  end

  def self.github_handle(user)
    user.github_handle.presence || fallback_handle(user)
  end

  def self.human_name(user)
    user.name.presence || user.github_handle.presence || user.email_address.to_s.split("@", 2).first.presence || "Syrus operator"
  end

  def self.fallback_handle(user)
    user.email_address.to_s.split("@", 2).first
      .downcase
      .gsub(/[^a-z0-9-]+/, "-")
      .gsub(/\A-+|-+\z/, "")
      .presence
  end
  private_class_method :fallback_handle

  def initialize(job)
    @job = job
    @repository = job.repository
    @user = job.user
  end

  def git_name
    if app_author?
      "#{app_slug}[bot]"
    else
      self.class.human_name(@user)
    end
  end

  def git_email
    if app_author?
      "#{app_slug}[bot]@users.noreply.github.com"
    else
      @user.email_address
    end
  end

  def co_authored_by_trailer
    return nil if @job.cron?
    return nil if @user.blank? || @user.email_address.blank?

    "Co-Authored-By: #{self.class.human_name(@user)} <#{@user.email_address}>"
  end

  def append_co_authored_by(message)
    trailer = co_authored_by_trailer
    return message if trailer.blank? || message.to_s.include?(trailer)

    [ message.to_s.rstrip, "", trailer ].join("\n")
  end

  private

  def app_author?
    app_slug.present? && AppSetting.github_app_registered? && @repository.installation&.active?
  end

  def app_slug
    AppSetting.current.github_app_slug.to_s.presence
  end
end
