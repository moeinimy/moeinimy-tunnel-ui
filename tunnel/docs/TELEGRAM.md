# Telegram setup

Telegram is **optional**. The whole project works without it; enabling it adds
notifications and a remote command bot.

## 1. Create a bot
1. Open Telegram and message [@BotFather](https://t.me/BotFather).
2. Send `/newbot`, choose a name and username.
3. Copy the **bot token** (looks like `123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxx`).

## 2. Find your chat id
1. Message [@userinfobot](https://t.me/userinfobot) — it replies with your
   numeric **chat id** (e.g. `987654321`).
2. Send any message to your new bot first (bots can't message you until you do).

## 3. Configure
```bash
sudo tunnelctl telegram config
```
Paste the token and chat id. A test message is sent immediately; on success the
command bot (`tm-bot.service`) is enabled automatically.

Credentials are stored at `/etc/tunnel-manager/telegram.conf` (`chmod 600`,
root-only).

## Notifications you will receive
- Tunnel up / down / recovered / failed to start
- Restart and removal events
- High CPU / RAM / disk usage (rate-limited)
- Daily report (08:00 by default — change `tm-report.timer`)
- Update applied

## Bot commands
| Command | Action |
|---------|--------|
| `/status`, `/tunnels` | overview of every tunnel |
| `/system` | CPU / RAM / disk / uptime |
| `/bandwidth` | live RX/TX per tunnel |
| `/report` | full daily report on demand |
| `/logs <name>` | recent logs for a tunnel |
| `/restart <name>` | restart a tunnel |
| `/reboot` | reboot the server |
| `/help` | command list |

Only your configured chat id is authorized; other chats get "Unauthorized".

## Disable
```bash
sudo tunnelctl telegram disable
```

## Multiple servers, one chat
Configure the same chat id on every server. Each message is prefixed with the
server's `hostname`, so you can tell them apart. Give each server's bot a
different token (or reuse one token — messages still arrive), and set distinct
hostnames for clarity.
