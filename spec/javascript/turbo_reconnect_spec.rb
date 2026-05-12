require "rails_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "turbo reconnect JavaScript" do
  it "resubscribes stale Turbo cable stream sources when the tab is visible" do
    Dir.mktmpdir("turbo-reconnect") do |dir|
      module_path = File.join(dir, "turbo_reconnect.mjs")
      FileUtils.cp Rails.root.join("app/javascript/turbo_reconnect.js"), module_path

      script = <<~JS
      import assert from "node:assert/strict"
      import { pathToFileURL } from "node:url"

      const listeners = { document: {}, window: {} }
      let sources = []

      globalThis.document = {
        hidden: false,
        addEventListener(name, callback) {
          listeners.document[name] = callback
        },
        querySelectorAll(selector) {
          assert.equal(selector, "turbo-cable-stream-source")
          return sources
        }
      }

      globalThis.window = {
        addEventListener(name, callback) {
          listeners.window[name] = callback
        }
      }

      const mod = await import(pathToFileURL(#{module_path.to_json}).href)

      const stale = {
        subscription: {},
        disconnected: 0,
        connected: 0,
        hasAttribute(name) {
          assert.equal(name, "connected")
          return false
        },
        disconnectedCallback() {
          this.disconnected += 1
        },
        connectedCallback() {
          this.connected += 1
        }
      }

      const alreadyConnected = {
        subscription: {},
        disconnected: 0,
        connected: 0,
        hasAttribute() {
          return true
        },
        disconnectedCallback() {
          this.disconnected += 1
        },
        connectedCallback() {
          this.connected += 1
        }
      }

      const notReady = {
        disconnected: 0,
        connected: 0,
        hasAttribute() {
          return false
        },
        disconnectedCallback() {
          this.disconnected += 1
        },
        connectedCallback() {
          this.connected += 1
        }
      }

      sources = [stale, alreadyConnected, notReady]
      mod.reconnectStaleCableStreamSources()

      assert.equal(stale.disconnected, 1)
      assert.equal(stale.connected, 1)
      assert.equal(alreadyConnected.disconnected, 0)
      assert.equal(notReady.disconnected, 0)

      document.hidden = true
      mod.reconnectStaleCableStreamSources()
      assert.equal(stale.disconnected, 1)

      assert.equal(typeof listeners.document.visibilitychange, "function")
      assert.equal(typeof listeners.window.focus, "function")
      assert.equal(typeof listeners.window.pageshow, "function")
      JS

      _stdout, stderr, status = Open3.capture3("node", "--input-type=module", stdin_data: script)

      expect(status).to be_success, stderr
    end
  end
end
