require "rails_helper"

# The service worker and its fallback document are what stand between an
# installed PWA and the ingress's 502 during a rolling deploy. Both have to be
# reachable with no session, because the fallback is fetched at worker-install
# time and served from cache when the app behind it cannot respond.
RSpec.describe "PWA deploy resilience", type: :request do
  describe "GET /pwa/unavailable" do
    it "renders without a session" do
      get "/pwa/unavailable"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Syrus is getting ready")
    end

    # If this page pulled in the SPA bundle it would be useless: that asset is
    # served by the very app that is not answering.
    it "is standalone — no SPA bundle, stylesheet, or layout chrome" do
      get "/pwa/unavailable"

      expect(response.body).not_to include("syrus-spa-root")
      expect(response.body).not_to match(/<script[^>]+src=/)
      expect(response.body).not_to match(/<link[^>]+stylesheet/)
    end

    it "polls the health endpoint and returns the user to where they were" do
      get "/pwa/unavailable"

      expect(response.body).to include("/up")
      expect(response.body).to include("syrus.unavailable.returnTo")
    end

    # The worker precaches this page while the user is signed in, so it is the
    # signed-in user's locale that ends up baked into the cached copy -- which
    # is the only locale signal available later, when the app is unreachable.
    it "localizes its copy to the signed-in user" do
      sign_in_as(Factories.user(locale: "de"))

      get "/pwa/unavailable"

      expect(response.body).to include(I18n.t("spa.startup.unavailable_title", locale: :de))
      expect(response.body).to include('lang="de"')
    end
  end

  describe "GET /service-worker.js" do
    it "serves the worker as JavaScript without a session" do
      get "/service-worker.js"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/javascript")
    end

    it "points at the real fallback route and carries the build sha in its cache name" do
      get "/service-worker.js"

      expect(response.body).to include("/pwa/unavailable")
      expect(response.body).to include("syrus-shell-#{SyrusVersion.current}")
    end

    # A worker cached by an intermediary would pin clients to an old policy.
    it "is not cacheable by intermediaries" do
      get "/service-worker.js"

      expect(response.headers["Cache-Control"]).to include("no-cache")
    end
  end
end
