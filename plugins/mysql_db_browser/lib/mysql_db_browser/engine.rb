module MysqlDbBrowser
  class Engine < ::Rails::Engine
    config.after_initialize do
      MysqlDbBrowser.register!
    end
  end
end
