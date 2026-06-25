Rails.application.config.after_initialize do
  Features::SyncFromYaml.call unless Rails.env.test?
end
