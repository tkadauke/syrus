module MysqlDbBrowser
  class Engine < ::Rails::Engine
    config.to_prepare do
      MysqlDbBrowser.register!
    end
  end
end
