class Installation < ApplicationRecord
  TOKEN_REFRESH_WINDOW = 5.minutes
  ACCESS_TOKENS_PATH = "/app/installations/%<id>s/access_tokens".freeze

  encrypts :cached_token

  belongs_to :user
  has_many :repositories, dependent: :nullify

  validates :github_installation_id, presence: true, uniqueness: true
  validates :account_login, presence: true
  validates :account_id, presence: true
  validates :account_type, presence: true, inclusion: { in: %w[User Organization] }
  validates :installed_at, presence: true

  scope :active, -> { where(removed_at: nil) }

  def active?
    removed_at.blank?
  end

  def fresh_token
    return cached_token if cached_token.present? && cached_token_expires_at.present? && cached_token_expires_at > TOKEN_REFRESH_WINDOW.from_now

    refresh_token!
  end

  private

  def refresh_token!
    settings = AppSetting.current
    raise ArgumentError, "GitHub App is not configured" if settings.github_app_id.blank? || settings.github_app_private_key_pem.blank?

    response = Faraday.post(
      "#{GithubAppClient::API_ROOT}#{format(ACCESS_TOKENS_PATH, id: github_installation_id)}"
    ) do |req|
      req.headers["Accept"] = "application/vnd.github+json"
      req.headers["Authorization"] = "Bearer #{GithubAppClient.app_jwt(settings)}"
      req.headers["User-Agent"] = GithubClient::USER_AGENT
      req.headers["X-GitHub-Api-Version"] = "2022-11-28"
    end
    raise github_error(response) unless response.success?

    payload = JSON.parse(response.body)
    update!(
      cached_token: payload.fetch("token"),
      cached_token_expires_at: Time.iso8601(payload.fetch("expires_at"))
    )
    cached_token
  end

  def github_error(response)
    case response.status
    when 401 then Octokit::Unauthorized.new(response)
    when 404 then Octokit::NotFound.new(response)
    else Octokit::Error.new(response)
    end
  end
end
