class PlatformIdentity < ApplicationRecord
  PLATFORMS = %w[ telegram slack ].freeze

  belongs_to :user

  after_commit :broadcast_linked, on: [ :create, :update ]

  validates :platform, presence: true, inclusion: { in: ->(_record) { PlatformIdentity.available_platforms } }
  validates :external_id, presence: true
  validates :linked_at, presence: true
  validates :external_id, uniqueness: { scope: :platform, message: "is already linked to a Syrus account" }

  def self.available_platforms
    PLATFORMS + Syrus::PluginRegistry.providers_for(:platform_delivery).map { |provider| provider.platform_key.to_s }
  end

  private

  def broadcast_linked
    AppEvents.broadcast(
      user: user,
      type: "platform_identity_linked",
      resource: "platform_identity",
      id: id,
      changed: [ "platform_identities" ],
      payload: ::App::PlatformIdentitiesPayload.for(user)
    )
  end
end
