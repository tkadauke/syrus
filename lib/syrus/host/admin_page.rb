require "syrus/host"
require "syrus/plugin/admin_page"

module Syrus
  module Host
    AdminPage = Syrus::Plugin::AdminPage unless const_defined?(:AdminPage, false)
  end
end
