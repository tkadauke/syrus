module App
  class PlatformIdentitiesPayload
    def self.for(user)
      new(user).as_json
    end

    def initialize(user)
      @user = user
    end

    def as_json
      {
        platform_identities: identities.map { |identity| identity_json(identity) },
        available_platforms: available_platforms_json
      }
    end

    private

    attr_reader :user

    def identities
      user.platform_identities.order(:platform)
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
      PlatformIdentity.available_platforms.map do |platform|
        {
          platform: platform,
          configured: PlatformIdentity::PlatformConfig::Base.for(platform).configured?
        }
      end
    end
  end
end
