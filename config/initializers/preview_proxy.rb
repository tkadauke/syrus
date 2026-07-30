require Rails.root.join("app/middleware/preview_proxy_middleware").to_s

Rails.application.config.middleware.insert_before 0, PreviewProxyMiddleware
