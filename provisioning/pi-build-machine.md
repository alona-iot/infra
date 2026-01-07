# Alona IoT — Using the Raspberry Pi as the Build Machine (Pi 5 / 64-bit Bookworm)

This guide explains how to build **Alona Core** (Elixir/Phoenix) releases **on the Raspberry Pi itself**, and then deploy them using the infra layout.

It’s meant for bring-up / early development, when you want the simplest path with the fewest cross-platform surprises.

---

## Does making the Pi the build machine change the architecture?

**No change to the repo architecture** (core / infra / protocol / firmware / docs stays the same).

What changes is the **operational posture**:

- The Pi becomes **both**:
  - a runtime host (systemd services, MQTT, DB), **and**
  - a build host (Elixir/Erlang toolchain, compilers, node tooling if needed)

Tradeoffs:

### Pros
- Zero cross-arch/cross-OS headaches (you build on the exact target: Linux ARM64).
- Fastest way to get to “it runs”.

### Cons
- More packages on the Pi (bigger attack surface, more moving parts).
- Builds write lots of small files → **SD wear** (SSD recommended if possible).
- You drift away from “immutable artifact deploy” (release-only) philosophy.

A good compromise is: **use the Pi as builder now**, and later move builds to CI/Docker and keep the Pi release-only.

---

## Prerequisites (already handled by infra installer)

Your `infra/scripts/install.sh` creates these paths:
- `/etc/alona`
- `/var/lib/alona/db`
- `/opt/alona-core/releases`  
…and the `alona` system user. (See `ensure_user_dirs()` in infra installer.)

So you should already have the runtime directories in place.

---

## Step 1 — Install build dependencies

### 1A) Required OS packages (recommended baseline)
```bash
sudo apt update
sudo apt install -y \
  git curl ca-certificates unzip \
  build-essential \
  libssl-dev zlib1g-dev libncurses5-dev libncurses-dev \
  libreadline-dev libffi-dev libyaml-dev \
  sqlite3 libsqlite3-dev
```

> If you later add NIFs or dependencies that need extra libs, you may need to extend this.

---

## Step 2 — Install Erlang/OTP + Elixir

You have two choices:

### Option A (recommended): install via `asdf` (pin exact versions)
This is best if you want reproducible builds and to match your dev/CI versions.

1) Install `asdf`:
```bash
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc
```

2) Add plugins:
```bash
asdf plugin add erlang
asdf plugin add elixir
```

3) Install versions (example: OTP 27 + Elixir 1.18.x — adjust to what you want):
```bash
asdf install erlang 27.2
asdf install elixir 1.18.2-otp-27
```

4) Set them globally (or per-project via `.tool-versions`):
```bash
asdf global erlang 27.2
asdf global elixir 1.18.2-otp-27
```

Verify:
```bash
elixir -v
erl -version
```

### Option B (quick): apt install
This is faster but versions may be older than you want.
```bash
sudo apt install -y erlang elixir
elixir -v
```

---

## Step 3 — Get the `core` repo on the Pi

Example:
```bash
mkdir -p ~/alona-iot
cd ~/alona-iot
git clone <YOUR_CORE_REPO_URL> core
cd core
```

(Or `git pull` if it exists.)

---

## Step 4 — Build a production release

From `~/alona-iot/core`:

```bash
cd ~/alona-iot/core

# Fetch deps
mix deps.get

# Compile for prod
MIX_ENV=prod mix compile

# If you have Phoenix assets, you likely need:
# MIX_ENV=prod mix assets.deploy

# Build the release
MIX_ENV=prod mix release
```

Your release will be in:
- `_build/prod/rel/<app_name>/`

---

## Step 5 — Deploy the release into the infra release directory

The infra installer created:
- `/opt/alona-core/releases`

We’ll deploy a timestamped version and update a `current` symlink.

1) Choose a version string:
```bash
VER="$(date +%Y%m%d%H%M%S)"
echo "$VER"
```

2) Discover the release folder name:
```bash
REL_DIR="$(ls -d _build/prod/rel/* | head -n 1)"
APP_NAME="$(basename "$REL_DIR")"
echo "APP_NAME=$APP_NAME"
```

3) Copy the release into place:
```bash
sudo mkdir -p "/opt/alona-core/releases/$VER"
sudo cp -a "$REL_DIR/." "/opt/alona-core/releases/$VER/"
```

4) Fix ownership (so the `alona` service user can run it):
```bash
sudo chown -R alona:alona /opt/alona-core/releases
```

5) Update the `current` symlink atomically:
```bash
sudo ln -sfn "/opt/alona-core/releases/$VER" /opt/alona-core/current
```

---

## Step 6 — Ensure core env exists

The infra installer copies an example env if missing:
- `/etc/alona/core.env`

Check:
```bash
sudo ls -la /etc/alona/core.env
sudo cat /etc/alona/core.env
```

Edit as needed:
```bash
sudo nano /etc/alona/core.env
```

---

## Step 7 — Start (or restart) the systemd service

Reload units (only needed after unit changes, safe to run anyway):
```bash
sudo systemctl daemon-reload
```

Restart core:
```bash
sudo systemctl restart alona-core
sudo systemctl status alona-core --no-pager
```

Logs:
```bash
journalctl -u alona-core -n 200 --no-pager
```

---

## Step 8 — Verify infra status

```bash
cd ~/alona-iot/infra
sudo ./scripts/status.sh
```

You want:
- `alona-core: active`
- `current:` not missing
- DB path present (often created by the app once it starts, depending on your implementation)

---

## Notes and best practices (Pi as builder)

- Prefer SSD over SD card for frequent builds.
- Keep build artifacts out of `/var/lib/alona` (that area is for runtime data).
- If you rebuild often, consider clearing old `_build` / `deps` occasionally:
  ```bash
  rm -rf _build deps
  ```
- When you’re ready for “production-like” deploys, move builds off the Pi and deploy only tarballs.

---

## If it doesn’t start: check what systemd expects

The exact `ExecStart` and working directory are defined in:
```bash
cat /etc/systemd/system/alona-core.service
```

Make sure the service points to something that exists under:
- `/opt/alona-core/current/`

If the service expects a different path or a different `bin/<name>` entrypoint, adjust either the service or your deploy path.
