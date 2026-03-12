# socks5-debian-installer

SOCKS5 manager script for Debian/Ubuntu.

Main script: `manage_socks5.sh`

## Interactive Menu

```bash
chmod +x manage_socks5.sh
./manage_socks5.sh
```

Menu options:

- `1` Install/Reinstall
- `2` Update
- `3` Show Config
- `4` Status
- `5` Test Proxy
- `6` Remove
- `0` Exit

## CLI Mode

Install:

```bash
./manage_socks5.sh install --port 8888 --user king
```

Update:

```bash
./manage_socks5.sh update --port 34578 --pass 'NewStrongPassword'
```

Remove:

```bash
./manage_socks5.sh remove
./manage_socks5.sh remove --purge
```

## Manual Proxy Test

```bash
curl --proxy "socks5h://<server_ip>:<port>" --proxy-user "<user>:<pass>" -sS https://api.ipify.org && echo
```
