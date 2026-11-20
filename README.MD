## This is for storing my configs

- [x] add default apps
- [ ] configure nchat
- [x] add proper gitignore

### What is (intentionally) not here

Only human-editable configuration is tracked. The following are kept out on
purpose so this repo is safe to publish:

- **Browser profiles** (`mozilla/`, `google-chrome*/`, `zen/`, ...) — these hold
  saved passwords, cookies, browsing history and bookmarks.
- **Secrets** — `.env`, `*.pem`, `*.key`, tokens, credential files are ignored.
- **App runtime data** — caches, session state, and generated databases
  (e.g. `libreoffice/`, `GIMP/3.0/`, `session/`).

If you fork this, generate any credentials locally; none are included here.
