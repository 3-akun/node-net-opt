# node-net-opt

Debian 12 / Ubuntu 22.04 一键优化（SS / Hy2 / VLESS-Reality）。

## 一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/3-akun/node-net-opt/main/install.sh | bash
```

## 功能

- BBR2/BBR + fq（TCP：SS、VLESS-Reality）
- UDP 缓冲与 conntrack（Hy2）
- Systemd `LimitNOFILE` + 常见代理服务 drop-in
- IP 转发（WARP / TUN / WireGuard）
- TIME-WAIT：`tcp_tw_reuse` + `tcp_max_tw_buckets`（按 1G/2G 分档）
- 固定 3 个 sysctl 文件 + 1 个 systemd 配置，可重复执行

## 安装后验证（Hy2 / hysteria-server）

drop-in 的 `LimitNOFILE` 需重启服务后才会生效。进程名为 `hysteria`（不是 `hysteria-server`），建议用 systemd 取 PID：

```bash
systemctl restart hysteria-server
cat /proc/$(systemctl show -p MainPID --value hysteria-server)/limits | grep 'Max open files'
systemctl status hysteria-server --no-pager
```

预期看到 `Max open files 524288 524288`。

## 回滚

```bash
rm -f /etc/sysctl.d/99-node-net-opt.conf \
      /etc/modules-load.d/99-node-net-opt.conf \
      /etc/security/limits.d/99-node-net-opt.conf \
      /etc/systemd/system.conf.d/99-node-net-opt.conf \
      /etc/systemd/system/*.service.d/99-node-net-opt.conf
systemctl daemon-reexec
sysctl --system
```
