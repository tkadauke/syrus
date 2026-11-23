# Local setup

1. Install Xcode (with an iOS simulator runtime). `brew install xcodegen` is
   only needed if you change `project.yml` or add files.
2. Start a Syrus server (for example `bin/dev` at the repo root, which serves
   on `http://localhost:3000`).
3. Open `ios/Syrus.xcodeproj`, choose an iPhone simulator, press Run. Debug
   builds pre-fill `http://localhost:3000` on the connection screen; the
   simulator shares the Mac's network, so `localhost` reaches the dev server.
4. Run tests with Cmd-U or the `xcodebuild test` command in the README.

Debug builds enable Safari Web Inspector for the web view (Safari > Develop >
your simulator).

## Running on a physical device

Set your team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in
`project.yml` and regenerate). Use the Mac's LAN address or hostname as the
server; `localhost` means the phone itself.

## Troubleshooting

- *Server unreachable*: the app shows the failure with Try again / Change
  server. Check the address and that the server listens on all interfaces.
- *Plain HTTP*: allowed for local networking and web content so self-hosted
  LAN/tailnet servers work; prefer HTTPS for anything reachable beyond that.
