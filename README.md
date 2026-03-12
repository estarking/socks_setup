# socks5-debian-installer

一个 Debian/Ubuntu 上管理 SOCKS5 的脚本。

主脚本：`manage_socks5.sh`

## 快速使用

```bash
chmod +x manage_socks5.sh
```

安装：

```bash
./manage_socks5.sh install --port 8888 --user king
```

修改（端口/账号/密码）：

```bash
./manage_socks5.sh update --port 34578 --pass 'NewStrongPassword'
```

查看当前配置：

```bash
./manage_socks5.sh show
./manage_socks5.sh show --show-pass
```

查看服务状态：

```bash
./manage_socks5.sh status
```

本机测试代理：

```bash
./manage_socks5.sh test
./manage_socks5.sh test --test-url https://google.com
```

删除配置并停服务：

```bash
./manage_socks5.sh remove
```

彻底卸载（含 xray）：

```bash
./manage_socks5.sh remove --purge
```

## 常用参数

- `--port` 端口
- `--user` 用户名
- `--pass` 密码（不传则自动生成）
- `--allow-ip` 限制来源 IP（如 `1.2.3.4/32`）
- `--enable-ufw | --disable-ufw`
- `--enable-udp | --disable-udp`

## 代理连通性手动测试

```bash
curl -x "socks5h://<user>:<pass>@<server_ip>:<port>" -sS https://google.com && echo
```
