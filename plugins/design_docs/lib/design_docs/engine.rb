module DesignDocs
  class Engine < ::Rails::Engine
    config.to_prepare do
      DesignDocs::HostAssociations.apply!
    end

    config.after_initialize do
      DesignDocs.register!
    end
  end
end
