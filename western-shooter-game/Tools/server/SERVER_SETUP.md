# Running servers on the Ubuntu laptop

Everything runs from the same exported Linux build (Project > Export > Linux, Export Mode: "Export as dedicated server").
Copy the build to the laptop, e.g. `/home/taco/westernshooter/`, and `chmod +x WesternShooter.x86_64`.

## What runs

| Program | Command | Port |
|---|---|---|
| Master server (server list + Quick Play) | `WesternShooter.x86_64 --headless -- --master --spawn` | TCP 8910 |
| Game server(s) | `WesternShooter.x86_64 --headless -- --server --mode=deathmatch --port=9998 --name="Taco's Saloon"` | UDP game port + UDP game port+100 |

* `--spawn` lets the master start new game servers by itself when someone presses PLAY and nothing is free
  (they shut down after 5 minutes with nobody playing). Without `--spawn`, only the servers you start yourself are listed.
* Modes: `team_vs_team` (add `--submode="Capture the Flag"` if wanted), `deathmatch`, `wave_survival`.
* Game servers on the same machine find the master at `http://127.0.0.1:8910` automatically.
  If the master runs elsewhere, add `--master=http://<host>:8910`.
* Keep game ports between 9990 and 10009 - LAN discovery only looks there.

Check it's working: open `http://<laptop-ip>:8910/` in a web browser - it lists all running servers.

## Firewall / router

```bash
sudo ufw allow 8910/tcp           # master server
sudo ufw allow 9990:10009/udp     # games
sudo ufw allow 10090:10109/udp    # server info / ping
```
For players outside your home network, forward the same ports on the router to the laptop
(and see the CGNAT note: if your router's WAN IP differs from `curl ifconfig.me`, use Tailscale or playit.gg instead).

## Start on boot (systemd)

`/etc/systemd/system/westernshooter-master.service`
```ini
[Unit]
Description=Western Shooter master server
After=network-online.target

[Service]
User=taco
WorkingDirectory=/home/taco/westernshooter
ExecStart=/home/taco/westernshooter/WesternShooter.x86_64 --headless -- --master --spawn --max-servers=6
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```
Optional always-on game server: `/etc/systemd/system/westernshooter-tvt.service` - same as above but
`ExecStart=... --headless -- --server --mode=team_vs_team --port=9999 --name="VU Capture the Point"`.

```bash
sudo systemctl enable --now westernshooter-master westernshooter-tvt
journalctl -u westernshooter-master -f
```
Laptop lid: set `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`, then `sudo systemctl restart systemd-logind`.

## Players

In the game: Browse Servers > "Master server" field > `http://<your-public-ip-or-ddns>:8910` > Save
(or change `DEFAULT_MASTER_URL` in `Scripts/Network/net_config.gd` before exporting so nobody has to type it).
