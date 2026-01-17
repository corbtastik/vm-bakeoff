# VM Bakeoff: Lima + Ubuntu (Apple Silicon) + MongoDB Community 🧪🍏

This repo is the start of a **VM bakeoff series**: running Linux VMs on **Apple Silicon** using **native Apple virtualization** where possible, and proving a consistent baseline setup across platforms.

> Blog Post: [VMs on macOS (Apple Silicon) with Lima](https://corbs.io/posts/vms-on-macos-(apple-silicon)-with-lima/)

✅ **Current status (this post):**
- **Lima** (CLI-first) on macOS
- **Ubuntu ARM64 VM** using **Virtualization.framework (VZ)**
- **MongoDB Community** installed in the VM
- MongoDB configured to store data on an **attached Lima data disk**
- Auth enabled with two users:
  - `dbAdmin` (admin/root)
  - `dbUser` (app user for the `todo` DB)
- Secrets stored at: `/etc/todo-secrets.env` (inside the VM, root-only)

> We intentionally keep MongoDB bound to `127.0.0.1` inside the VM for safety.

---

## Links 🔗
- Lima: https://lima-vm.io/
- Apple Virtualization.framework: https://developer.apple.com/documentation/virtualization
- Ubuntu ARM64: https://ubuntu.com/download/server/arm
- MongoDB on Ubuntu (official): https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/

---

## Repo structure 📁

```text
vm-bakeoff/
  Makefile
  drivers/
    lima.sh
  platforms/
    lima/
      lima.yaml              # generated/pinned VM config
  scripts/
    guest/
      provision.sh           # runs inside the VM (MongoDB + disk + auth)
    lima-pin-ubuntu.sh       # pins a Canonical Ubuntu image + sha256 into lima.yaml
    provision.sh
    up.sh
    down.sh
    destroy.sh
    status.sh
    ssh.sh
    endpoints.sh
```

---

## Prereqs on macOS ✅
- Homebrew (recommended)
- Lima (`limactl`)
- HTTPie (used by helper scripts)

Install:
```bash
brew install lima httpie
```

Check:
```bash
limactl --version
```

---

## Quickstart 🚀

### 1) Pin the Ubuntu image (deterministic)
Generates `platforms/lima/lima.yaml` pinned to a Canonical cloud image + SHA256.

```bash
make ubuntu-pin
```

### 2) Start the VM
```bash
make up PLATFORM=lima
```

### 3) SSH into the VM
```bash
make ssh PLATFORM=lima
```

---

## Provision MongoDB in the VM 🧩🍃

This runs the guest provisioning script to:

- bind-mount the attached Lima data disk to `/data`
- configure MongoDB `dbPath` under `/data/mongodb`
- enable auth and reconcile users/passwords idempotently

```bash
make provision PLATFORM=lima
```

---

## Verify inside the VM ✅

### View secrets (root-only)
```bash
sudo cat /etc/todo-secrets.env
```

### Connect as `dbUser` (app user)
```bash
sudo bash -lc 'source /etc/todo-secrets.env && mongosh "$MONGODB_URI"'
```

### Connect as `dbAdmin` (admin/root)
```bash
sudo bash -lc 'source /etc/todo-secrets.env && mongosh --host 127.0.0.1 --port 27017 --username "$DB_ADMIN_USER" --password "$DB_ADMIN_PASS" --authenticationDatabase admin'
```

### Prove auth is ON (unauthenticated call should fail)
```bash
mongosh --quiet --eval "db.getSiblingDB('admin').runCommand({usersInfo:1})"
```

Expected: ❌ requires authentication

---

## Teardown 🧨

Stop VM:
```bash
make down PLATFORM=lima
```

Delete VM:
```bash
make destroy PLATFORM=lima
```

> Note: the Lima **data disk** is managed separately (and currently preserved).  
> That’s intentional for the “persistence story.”

---

## Security notes 🔐
- Credentials are generated and stored **inside the VM** at `/etc/todo-secrets.env` with permissions `0600`.
- MongoDB is configured with `bindIp: 127.0.0.1` to prevent external exposure by default.
- If you later port-forward MongoDB to the host, prefer forwarding to a non-standard host port (e.g., `37017`).

---

## License
MIT (or your preference)