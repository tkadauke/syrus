WebAuthn.configure do |config|
  config.rp_name = "Syrus"

  if (app_host = ENV["SYRUS_APP_HOST"].presence)
    config.allowed_origins = [ "https://#{app_host}" ]
  else
    port = ENV["PORT"].presence || "3000"
    config.allowed_origins = [ "http://localhost:#{port}" ]
  end
end
