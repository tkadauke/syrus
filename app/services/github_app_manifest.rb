class GithubAppManifest
  TEMPLATE_PATH = Rails.root.join("config/github_app_manifest.json")

  def initialize(user:, callback_url:, webhook_url:)
    @user = user
    @callback_url = callback_url
    @webhook_url = webhook_url
  end

  def to_json(*)
    manifest.to_json
  end

  def manifest
    template.deep_dup.tap do |body|
      body["name"] = body["name"].sub("{operator-handle}", operator_handle)
      body["url"] = root_url
      body["redirect_url"] = @callback_url
      body["hook_attributes"]["url"] = @webhook_url
    end
  end

  private

  def template
    @template ||= JSON.parse(TEMPLATE_PATH.read)
  end

  def operator_handle
    @user.email_address.to_s.split("@", 2).first.downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "").presence || "operator"
  end

  def root_url
    @callback_url.sub(%r{/admin/github_app/callback\z}, "")
  end
end
