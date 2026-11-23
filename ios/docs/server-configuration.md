# Server configuration

The app stores the selected server and up to five recent servers in
`UserDefaults` (`ServerStore`). No credentials are stored natively: you sign in
inside the web view and the session cookie lives in WebKit's persistent store.

- Input like `syrus.example.com` becomes `https://syrus.example.com`.
  `localhost`, loopback, RFC 1918 addresses and `.local` hosts default to
  `http`. Paths (reverse-proxy prefixes) are kept; credentials, query and
  fragment are dropped.
- Debug builds suggest `http://localhost:3000`; Release builds suggest nothing.
- Use the ellipsis menu > Switch server to return to the connection screen.
  Switching first removes this device's push registration from the old server.
- Same-origin links load in the app; other origins open in the system browser.
