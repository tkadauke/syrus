class Coworkers::JobVisibilityRestriction
  include Syrus::Host::JobVisibilityRestriction

  def self.origin_key = "coworkers"

  def self.visible_origin_ids(user:)
    Coworkers::Coworker.where(owner_user: user).select(:id)
  end
end
