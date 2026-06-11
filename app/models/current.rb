class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user

  def user
    session&.user || api_user
  end
end
