# RAD

This is rad.

## Build

    npm run dev                 development build in web/, the example target
    RAD_TARGET=<target> npm run dev   … of another target, also for npm run build
    npm run dist                all targets, each into dist/<target>
    npm run dist -- <target>    one target
    npm run deploy -- <target>  build and upload it to DEPLOY_<TARGET> of .env

## Targets

A target is a distribution of rad, a folder in `targets/`. Only `targets/example` is in git, copy it for your own:

- `config.json`, see `Login.Config`, all optional:
  - `domain`: added to a name entered without one, the login asks for a username
  - `websocket`: the WebSocket endpoint, default `wss://<domain>/xmpp-websocket`, the field is hidden
  - `room`: the room to join, the field is hidden
  - `conference`: the MUC service, users only enter the room name
  - `defaultRoom`: filled in when no room was used before
  - `nickField`: `false` hides the nick field, the nick is the user name
  - `scheme`: `"dark"` or `"light"`, for a theme with one color scheme only, hides the choice in the settings
- `theme.scss`: the stylesheet, configures `src/style/_theme.scss` (fonts, colors) and adds rules.
