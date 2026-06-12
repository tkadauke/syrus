class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user

  def user
    api_user || session&.user
  end
end
