require "tailscale/version"

module Tailscale
  def self.enabled?
    Syrus::PluginRegistry.providers_for(:admin_page).include?(AdminPages)
  end
end

require "tailscale/engine"
