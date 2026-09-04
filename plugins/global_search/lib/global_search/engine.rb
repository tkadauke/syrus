module GlobalSearch
  class Engine < ::Rails::Engine
    config.to_prepare do
      GlobalSearch.register!
    end
  end
end
