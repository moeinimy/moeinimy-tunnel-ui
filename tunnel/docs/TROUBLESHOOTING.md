# Troubleshooting

Start by collecting the basics on the affected server and share them if you ask
for help:
```bash
cat /etc/os-release | head -3; uname -r; systemd-detect-virt
sudo tunnelctl list
sudo tunnelctl status <name>
sudo journalctl -u tm-tunnel-<name> -n 50 --no-pager
sudo journalctl -u tm-monitor -n 50 --no-pager
sudo tail -n 50 /var/log/tunnel-manager/tunnel-manager.log
```

## GRE

**`ip_gre kernel module not loaded` / interface never appears**
Your VPS is almost certainly OpenVZ or LXC, which don't expose GRE. Confirm:
```bash
sudo modprobe ip_gre; echo $?      # non-zero = not allowed
systemd-detect-virt                # openvz / lxc → use Paqet instead
```
Switch that tunnel to **Paqet**.

**`ping` to the inner IP fails, but the tunnel actually works**
This is common on Iran paths: **ICMP inside GRE is often filtered while TCP
passes fine.** Don't judge a GRE tunnel by `ping`. Test with TCP instead:
```bash
# on the foreign side, listen on its inner IP
python3 -m http.server 8080 --bind 10.20.0.5
# from the Iran side
curl -v --max-time 10 http://10.20.0.5:8080/
```
If curl connects, the tunnel is healthy. Tunnel Manager's monitor already falls
back to a TCP probe, so `tunnelctl status` reports reachability correctly (look
for `(tcp probe)`), even when ICMP is dropped.

**Interface is up but even TCP through the tunnel fails**
- GRE uses IP protocol 47 — make sure your provider/firewall allows it both ways.
- Check both ends have the *mirror* config (Iran `remote` = foreign public IP and
  vice-versa) and the **same GRE key** if you set one.
- Verify the inner addresses are the expected `/30` pair (`tunnelctl status`).
- Make sure no leftover GRE tunnel from another script shares the same endpoints
  (a second keyless GRE between the same IPs collides): `ip -d link show | grep gre`.

**Traffic doesn't route through the tunnel**
- On the foreign side enable NAT (re-run `edit`, or recreate with NAT = yes).
- Confirm forwarding: `sysctl net.ipv4.ip_forward` should be `1`
  (`tunnelctl optimize apply` sets it).

## Paqet

**Binary download failed**
```bash
# Pin a version or repo in settings, then retry:
sudo sed -i 's/^# PAQET_VERSION=.*/PAQET_VERSION=v1.0.0-alpha.20/' /etc/tunnel-manager/settings.conf
sudo systemctl restart tm-tunnel-<name>
```
Or install the binary manually:
```bash
# download the matching paqet-linux-<arch>-<version>.tar.gz from the release page
sudo install -m0755 ./paqet /opt/tunnel-manager/bin/paqet
```

**Service keeps restarting**
```bash
sudo journalctl -u tm-tunnel-<name> -n 80 --no-pager
```
Common causes: wrong `router_mac` (re-detect the gateway MAC), wrong interface,
port already in use, or a secret/mode mismatch between the two ends. The client
and server **must** share the same `key`, `mode`, `cipher`, `conn` and `mtu`.

**Find the gateway MAC manually**
```bash
gw=$(ip route show default | awk '/via/{print $3; exit}')
ping -c1 "$gw" >/dev/null; ip neigh show "$gw"
```

## Monitoring / recovery

**A tunnel flaps or won't auto-recover**
- Auto-recovery only touches tunnels that are *enabled* or *active*. If you
  stopped it manually it stays down by design — `tunnelctl start <name>`.
- Tune retries/interval in `settings.conf` (`TM_MONITOR_RETRIES`,
  `TM_MONITOR_INTERVAL`) and `sudo systemctl restart tm-monitor`.

## Telegram

**No messages arrive** — message your bot once first, verify the numeric chat id,
then `sudo tunnelctl telegram test`. Check `journalctl -u tm-bot`.

## Optimization

**A sysctl value was rejected** — some keys don't exist on every kernel; the rest
are still applied. Everything is reversible:
```bash
sudo tunnelctl optimize revert
```

## General

**Reset a single tunnel cleanly**
```bash
sudo tunnelctl stop <name> && sudo tunnelctl start <name>
```

**Completely start over**
```bash
sudo tunnelctl uninstall     # reverts optimization, removes services
sudo bash install.sh
```
