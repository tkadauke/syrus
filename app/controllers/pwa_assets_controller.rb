class PwaAssetsController < ApplicationController
  allow_unauthenticated_access only: :apple_touch_icon

  def apple_touch_icon
    expires_in 1.year, public: true
    send_file Rails.root.join("public/icon-192.png"), type: "image/png", disposition: "inline"
  end
end
