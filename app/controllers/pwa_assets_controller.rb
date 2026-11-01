class PwaAssetsController < ApplicationController
  allow_unauthenticated_access only: %i[ apple_touch_icon unavailable service_worker ]
  # Rails blocks cross-origin requests for JS-format responses so another site
  # cannot embed protected JavaScript via <script src>. A service worker script
  # is public and carries nothing session-specific, and the browser fetches it
  # as a worker rather than a script, so the protection only gets in the way --
  # this is the same exemption Rails' own pwa#service_worker relies on by being
  # routed without a .js extension.
  skip_forgery_protection only: :service_worker
  # Resumed, not required. The fallback page is precached while the user is
  # signed in, and the locale baked into that cached copy is the only locale
  # signal left by the time it is served -- but the page must still render for
  # a visitor with no session at all, which is why this cannot be
  # `require_authentication`.
  #
  # Prepended because ApplicationController's `around_action :switch_locale` is
  # declared first and would otherwise wrap -- and resolve the signed-in user's
  # locale -- before a plain `before_action` here had resumed the session.
  prepend_before_action :resume_session, only: :unavailable

  def apple_touch_icon
    expires_in 1.year, public: true
    send_file Rails.root.join("public/icon-192.png"), type: "image/png", disposition: "inline"
  end

  # The document the service worker serves when a navigation cannot reach the
  # app -- during a rolling deploy, the ingress answers 502 for the fraction of
  # a second before it stops routing at a terminating pod.
  #
  # Deliberately standalone: no SPA layout, no bundle, no database. The whole
  # point is to render when the app behind it cannot, and it is served from the
  # service worker's cache, so anything it referenced over the network would
  # fail for the same reason the navigation did. It polls `/up` and continues
  # by itself, because an installed PWA has no address bar to reload from.
  # Served from here rather than Rails' default `rails/pwa#service_worker` so
  # the worker can be an ERB template: it needs the cache name to carry the
  # build SHA and the fallback path to come from the router, not a hardcoded
  # string that silently rots if the route moves.
  def service_worker
    # No max-age: browsers revalidate worker scripts aggressively, but an
    # intermediary caching this would pin clients to an old worker.
    response.headers["Cache-Control"] = "no-cache"
    render template: "pwa/service_worker", content_type: "text/javascript", layout: false
  end

  def unavailable
    expires_in 5.minutes, public: true
    render template: "pwa/unavailable", layout: false
  end
end
