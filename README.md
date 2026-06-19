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
- `psono/psono-fileserver:latest` when file sharing is enabled
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

The installer also asks for a hardening profile. The recommended profile is `balanced`; it enables an inbound firewall, Debian security updates, SSH hardening, and disables open Psono registration.

The installer asks whether to enable the Psono fileserver and defaults to yes. Fileserver support uses local VM storage in this first version.

The login is rendered into the custom cloud-init user-data used by this installer.

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
  --hardening-profile balanced \
  --fileserver true \
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
  --tailscale-ssh false \
  --ssh-exposure lan \
  --fileserver true \
  --tailscale-auth-key tskey-auth-...
```

Tailscale public Funnel example:

```bash
bash setup-psono-vm.sh \
  --access-mode tailscale-https \
  --tailscale-exposure funnel \
  --hardening-profile balanced \
  --fileserver true \
  --tailscale-auth-key tskey-auth-...
```

Tailscale SSH example:

```bash
bash setup-psono-vm.sh \
  --access-mode tailscale-https \
  --tailscale-exposure serve \
  --tailscale-ssh true \
  --ssh-exposure tailscale \
  --fileserver true \
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

When fileserver is enabled, it listens on `127.0.0.1:10300` and is exposed through the same MagicDNS name at `/fileserver`.

This installer uses a full VM, not an LXC container. You do not need to enable a Proxmox-side TUN device for the guest. The VM has its own kernel, and the bootstrap checks `/dev/net/tun` inside Debian before starting Tailscale.

Tailscale SSH is optional and defaults to off. If enabled, the installer runs `tailscale up --ssh` so the VM can be reached through Tailscale SSH according to your tailnet's access controls.

With hardening enabled, regular OpenSSH access is controlled separately with `--ssh-exposure`:

- `lan`: allow port 22 from the VM network.
- `tailscale`: allow port 22 only through `tailscale0`.
- `disabled`: block regular port 22 access.

The Proxmox console remains the break-glass login path.

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

Caddy mode includes basic security headers and keeps Psono bound to `127.0.0.1:10200` behind the reverse proxy.

When fileserver is enabled, Caddy routes `/fileserver` to `127.0.0.1:10300`.

## Hardening

Hardening profiles:

- `none`: do not apply VM hardening.
- `minimal`: apply the firewall and SSH hardening.
- `balanced`: recommended; applies firewall, SSH hardening, unattended security updates, and disables public Psono registration.
- `strict`: like balanced, and disables password SSH in the VM.

The firewall uses `nftables`:

- default inbound deny
- loopback, established traffic, ICMP, outbound traffic allowed
- Tailscale UDP and selected Tailscale HTTPS/SSH traffic allowed
- `lab-http`: opens `10200/tcp`
- `caddy-https`: opens `80/tcp` and `443/tcp`
- `tailscale-https`: opens no LAN Psono port
- fileserver port `10300/tcp` is opened only in `lab-http`

For an existing VM:

```bash
sudo psonoctl harden --profile balanced --ssh-exposure tailscale
sudo psonoctl doctor
```

This installer does not add Watchtower. Use `sudo psonoctl update` so backups, migrations, and health checks run in the intended order.

## Optional Setup

The installer can also configure:

- Psono fileserver with local VM shard storage
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
sudo psonoctl create-user user@example.com
sudo psonoctl promote-user username@example.com superuser
sudo psonoctl test-email user@example.com
sudo psonoctl clear-token
sudo psonoctl fix-email-salt
sudo psonoctl fingerprint
sudo psonoctl harden
sudo psonoctl doctor
sudo psonoctl fileserver-test
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

This installer intentionally does not use Watchtower or automatic container updates. Psono updates are not just image pulls: the app container should be stopped at the right point, database migrations need to run, the service needs a health check before cleanup, and PostgreSQL updates must stay within the pinned major version unless you explicitly run a major upgrade. `psonoctl update` keeps that order visible and recoverable.

When fileserver is enabled, `psonoctl update` also pulls and restarts `psono-fileserver` after the server migration flow.

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
- `/opt/psono/data/fileserver`
- `/opt/psono/data/fileserver-shards`
- `/opt/psono/docker-compose.yml`
- `/opt/psono/.env`

Cloudflare R2 uses restic's S3 backend:

```text
s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<bucket>/<prefix>
```

## Psono Maintenance

The installer runs Psono database migrations during bootstrap and updates.

It also creates a daily `psono-cleartoken.timer`, equivalent to Psono's documented `cleartoken` cron job.

If user creation fails with `Invalid salt`, update `psonoctl` and run `sudo psonoctl fix-email-salt`.

On first login, Psono may ask you to approve a server fingerprint. Verify it from the VM with `sudo psonoctl fingerprint`; the login screen should match the local `verify_key`.

## Files In The VM

```text
/opt/psono/docker-compose.yml
/opt/psono/.env
/opt/psono/data/postgres
/opt/psono/data/psono/settings.yaml
/opt/psono/data/psono/config.json
/opt/psono/data/fileserver/settings.yaml
/opt/psono/data/fileserver-shards
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
