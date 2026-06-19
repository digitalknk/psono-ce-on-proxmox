# Psono on Proxmox

A Proxmox host script that creates a small Debian VM and installs Psono Community Edition with Docker Compose.

It uses a VM because Psono's documented CE install uses Docker images and PostgreSQL.

Status: early homelab installer. Read the script before running it on a Proxmox host you care about.

## What It Creates

- Debian 13 VM
- 2 vCPU, 4096 MB RAM, 40 GB disk by default
- VM name `psono-<VMID>` by default
- Docker and Docker Compose inside the VM
- `psono/psono-combo:latest`
- `postgres:18-alpine`
- Psono files under `/opt/psono`
- `/usr/local/sbin/psonoctl` for day-to-day management

## Requirements

Run the installer from a Proxmox VE host shell as `root`.

The host needs:

- `qm`
- `pvesm`
- `pvesh`
- `curl` or `wget`
- storage for the VM disk, for example `local-lvm`
- snippet-capable storage for cloud-init, usually `local`

## Install

Run this on the Proxmox host:

```bash
PSONO_INSTALLER_BASE_URL="https://raw.githubusercontent.com/digitalknk/psono-ce-on-proxmox/main" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/digitalknk/psono-ce-on-proxmox/main/setup-psono-vm.sh)"
```

To print help without creating anything:

```bash
PSONO_INSTALLER_BASE_URL="https://raw.githubusercontent.com/digitalknk/psono-ce-on-proxmox/main" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/digitalknk/psono-ce-on-proxmox/main/setup-psono-vm.sh)" _ --help
```

From a checkout instead:

```bash
git clone https://github.com/digitalknk/psono-ce-on-proxmox.git
cd psono-ce-on-proxmox
bash setup-psono-vm.sh
```

The installer asks for the VM ID, storage, network bridge, VM login method, access mode, and optional features.

By default it asks for a password for the `psono` user and enables password SSH in cloud-init. You can choose SSH key login instead and either provide a public key file or paste the public key when prompted.

Multiple installs on the same Proxmox host are supported. Each install needs its own VMID and VM name. By default the script asks Proxmox for the next VMID and names the VM `psono-<VMID>`.

The Debian cloud image is cached under:

```text
/var/lib/vz/template/qcow2/
```

If the same image file already exists there, the installer reuses it instead of downloading it again. Pass `--refresh-image` to download a fresh copy, or `--image-url` to use a different image URL.

Most prompts can be prefilled with flags. For example:

```bash
bash setup-psono-vm.sh \
  --name psono \
  --cores 4 \
  --memory 8192 \
  --disk 80 \
  --storage local-lvm \
  --snippet-storage local \
  --bridge vmbr0 \
  --auth-method password \
  --password 'change-this-password' \
  --access-mode lab-http \
  --backup-mode none
```

SSH key example:

```bash
bash setup-psono-vm.sh \
  --auth-method ssh-key \
  --ssh-key /root/.ssh/id_rsa.pub
```

Tailscale tailnet-only example:

```bash
bash setup-psono-vm.sh \
  --access-mode tailscale-https \
  --tailscale-exposure serve \
  --tailscale-auth-key tskey-auth-...
```

Tailscale public Funnel example:

```bash
bash setup-psono-vm.sh \
  --access-mode tailscale-https \
  --tailscale-exposure funnel \
  --tailscale-auth-key tskey-auth-...
```

## Access Modes

### Lab HTTP

Publishes Psono directly on the VM:

```text
http://<VM-IP>:10200
```

Use this for a first test only. Psono's docs require a domain and trusted TLS for supported use.

### Tailscale HTTPS

Installs Tailscale in the VM and serves Psono over the VM's MagicDNS name.

For tailnet-only access, choose `serve`:

```bash
tailscale serve --bg --https=443 127.0.0.1:10200
```

For public access through Tailscale Funnel, choose `funnel`:

```bash
tailscale funnel --bg --https=443 http://127.0.0.1:10200
```

The installer asks for a Tailscale auth key. You can leave it blank and finish the normal Tailscale login from the URL printed in the VM bootstrap log. Funnel requires the tailnet-side Funnel settings that Tailscale documents, including MagicDNS, HTTPS certificates, and Funnel permission in the tailnet policy.

In Tailscale mode Psono listens only on `127.0.0.1:10200`.

This installer uses a full VM, not an LXC container. You do not need to enable a Proxmox-side TUN device for the guest. The VM has its own kernel, and the bootstrap checks `/dev/net/tun` inside Debian before starting Tailscale.

To create an auth key:

1. Open the Tailscale admin console.
2. Go to **Settings** -> **Keys**.
3. Create an auth key.
4. For this installer, an ephemeral key is not recommended because the VM should stay registered after reboot.
5. Copy the generated `tskey-auth-...` value and pass it with `--tailscale-auth-key`, or paste it when prompted.

Startup behavior:

- `tailscaled` is enabled with systemd.
- Psono and Postgres use Docker restart policies.
- `psono-tailscale-exposure.service` reapplies Serve or Funnel after boot.

### Caddy HTTPS

Installs Caddy and reverse proxies your domain to:

```text
127.0.0.1:10200
```

Use this when the VM can receive traffic for the domain and Caddy can complete ACME validation.

## Optional Setup

The installer can also configure:

- SMTP email
- YubiKey OTP
- restic backups to S3-compatible service (AWS, Cloudflare R2, Backblaze B2, Minio, etc.)

It does not configure Psono Enterprise-only features such as LDAP, OIDC, SAML, audit logging, compliance enforcement, or policies.

## Managing Psono

Run these inside the VM:

```bash
sudo psonoctl help
sudo psonoctl help update
sudo psonoctl status
sudo psonoctl health
sudo psonoctl start
sudo psonoctl stop
sudo psonoctl restart
sudo psonoctl logs -f
sudo psonoctl config
sudo psonoctl test-email user@example.com
sudo psonoctl backup
sudo psonoctl update
sudo psonoctl update --with-postgres
sudo psonoctl postgres-upgrade --target-major 19
```

## Updates

Update Psono:

```bash
sudo psonoctl update
```

That command:

1. Runs a backup unless `--skip-backup` is passed.
2. Pulls the latest Psono image.
3. Stops only the Psono container.
4. Runs Psono database migrations.
5. Starts Psono again.
6. Checks the local health endpoint.
7. Prunes old images after the health check passes.

Update the PostgreSQL patch image within the same major version:

```bash
sudo psonoctl update --with-postgres
```

PostgreSQL major upgrades are separate:

```bash
sudo psonoctl postgres-upgrade --target-major 19
```

Do not treat a major PostgreSQL upgrade like a normal app update. Take a Proxmox snapshot first.

## Backups

Local backups are written to:

```text
/opt/psono/backups/
```

If restic is configured, `psonoctl backup` also sends the backup to the configured R2 or S3-compatible repository.

Each backup includes:

- PostgreSQL dump
- `/opt/psono/data/psono`
- `/opt/psono/docker-compose.yml`
- `/opt/psono/.env`

Cloudflare R2 uses restic's S3 backend:

```text
s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<bucket>/<prefix>
```

## Files In The VM

```text
/opt/psono/docker-compose.yml
/opt/psono/.env
/opt/psono/data/postgres
/opt/psono/data/psono/settings.yaml
/opt/psono/data/psono/config.json
/opt/psono/README.md
/usr/local/sbin/psonoctl
/root/.config/psono-installer/
```

## Notes

- The VM gets its first IP from DHCP.
- The installer downloads the Debian 13 cloud image from Debian's cloud image mirror.
- Lab HTTP is useful for checking that the install works, but it is not the recommended long-term access mode.
- VM login uses the `psono` user.
- Store the restic password and S3/R2 credentials somewhere safe. They are written in the VM under `/root/.config/psono-installer/` with root-only permissions.
