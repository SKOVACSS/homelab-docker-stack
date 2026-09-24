# Uptime Kuma monitors (AutoKuma)

Every file in `monitors/` is one Uptime Kuma entity, kept in sync by the
`autokuma` service (see `../docker-compose.yml`). The file name (minus
`.json`) is its AutoKuma ID - `parent_name` and `notification_name_list`
refer to other entities by that ID.

Add a monitor by dropping in a file like this, then restart `autokuma`:

```json
{
  "type": "http",
  "name": "My App",
  "url": "http://my-app:8080/health",
  "parent_name": "apps",
  "interval": 60,
  "retry_interval": 60,
  "max_retries": 3,
  "accepted_statuscodes": ["200-399"],
  "notification_name_list": ["gotify"]
}
```

- Use the container's **internal** URL (`http://<container>:<port>`),
  never the public domain - keeps this repo domain-free, and a check
  doesn't depend on Cloudflare being up. Uptime Kuma has to share a
  Docker network with the target (it's on `caddy-network` and `utilities`).
- IDs are global across monitors, groups and notifications - a monitor
  file named `gotify.json` once collided with the `gotify` notification
  and the two overwrote each other on every sync.
- Groups: `media`, `apps`, `infra`. Notification: `gotify`, defined on
  the autokuma container's labels so its token comes from `.env`.
- **Don't monitor Sablier-managed apps** (Jellyfin, chat/Open WebUI, remote/Guacamole, pdf/Stirling-PDF):
  every check is a request, which would keep waking them up.
