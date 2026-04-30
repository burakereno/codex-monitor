# Claude Instructions

Follow the project rules in `AGENTS.md`.

Most important: after making any change, always run:

```sh
pkill -x CodexStatus || true
./scripts/build-app.sh
open .build/CodexStatus.app
```

