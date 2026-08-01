module App
  class PlatformIdentitiesPayload
    def self.call(user:, message: nil)
      new(user: user, message: message).call
    end

    def self.supported_platform?(platform)
      ExternalPlatforms.include?(platform)
    end

    def self.platform_configured?(platform)
      ExternalPlatforms.fetch(platform).configured?
    rescue KeyError
      false
    end

    def initialize(user:, message: nil)
      @user = user
      @message = message
    end

    def call
      payload = {
        platform_identities: identities.map { |identity| identity_json(identity) },
        available_platforms: available_platforms_json
      }
      payload[:message] = @message if @message.present?
      payload
    end

    private

    def identities
      @identities ||= @user.platform_identities.order(:platform)
    end

    def identity_json(identity)
      {
        id: identity.id,
        platform: identity.platform,
        external_handle: identity.external_handle,
        linked_at: identity.linked_at.iso8601
      }
    end

    def available_platforms_json
      ExternalPlatforms.all.map do |platform|
        {
          platform: platform.key,
          label: platform.label,
          configured: platform.configured?
        }
      end
    end

    def platform_configured?(platform)
      self.class.platform_configured?(platform)
    end
  end
end
