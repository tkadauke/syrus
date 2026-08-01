class PlatformIdentity < ApplicationRecord
  PLATFORMS = App::ExternalPlatforms.names.freeze

  belongs_to :user

  after_commit :broadcast_linked, on: [ :create, :update ]

  enum :platform, PLATFORMS.index_with(&:itself), validate: true

  validates :platform, presence: true, inclusion: { in: PLATFORMS }
  validates :external_id, presence: true
  validates :linked_at, presence: true
  validates :external_id, uniqueness: { scope: :platform, message: "is already linked to a Syrus account" }

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
