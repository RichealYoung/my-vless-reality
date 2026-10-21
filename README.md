# VLESS Reality + 指定域名 WARP 分流

用于在新服务器上快速复现部署方式：VLESS + TCP + Reality + `xtls-rprx-vision`，443/TCP；指定域名经 Cloudflare WARP 的本地 SOCKS5 代理出站，其他请求默认直连。

## 新服务器安装

支持 Ubuntu 22.04/24.04/26.04、Debian 12/13，x86_64 或 ARM64，要求运行 systemd、能连接 GitHub 与 Cloudflare。安装 WARP 即接受 Cloudflare 的服务条款；安装过程使用官方 APT 软件源。

这是私有仓库。推荐在已登录 GitHub 的本机下载，再通过 SSH 上传，不需要把 GitHub 令牌放到新服务器。下面在本机 PowerShell 执行，将 `新服务器公网IP` 替换为真实地址：

```powershell
git clone https://github.com/RichealYoung/my-vless-reality.git
scp .\my-vless-reality\install-reality.sh root@新服务器公网IP:/root/install-reality.sh
ssh root@新服务器公网IP 'bash /root/install-reality.sh 新服务器公网IP'
```

已有本地仓库时先 `git -C .\my-vless-reality pull --ff-only`，然后上传、运行。如果脚本已经在服务器上，直接执行 `bash /root/install-reality.sh 新服务器公网IP`。

不传 IP 时尝试自动获取公网 IPv4；存在 NAT 或其他代理时建议明确传入 IP。先下载再运行，不通过管道直接执行远程内容。

脚本会安装固定版本的 Xray v26.9.9 并校验发布包 SHA256，自动安装/注册 WARP 并设置为 **本地代理模式** `127.0.0.1:40000`，验证 `warp=on` 后部署 Xray，设置两个服务开机启动。它不会把整台服务器的默认路由切换到 WARP。

UUID、Reality 密钥和 Short ID 在每次全新安装时随机生成。安装结束后输出客户端导入链接，并保存到新服务器的 `/root/vless-reality-link.txt`。请导入新节点；现有服务器的凭据不会因 GitHub 上传或脚本更新而改变。

启用中的 UFW 会放行 443/TCP；云厂商防火墙/安全组仍需允许 443/TCP。云厂商可能限制 WARP 隧道或服务注册，脚本遇到 WARP 不通会报错，不会宣称部署成功。安装成功仍需在客户端验证公网连接和目标站点访问。

## 默认 WARP 域名

所有条目都包含域名本身及其子域名：

| 服务 | 域名 |
| --- | --- |
| Grok / xAI | `grok.com`、`x.ai`、`grok.x.com`、`grokipedia.com` |
| LeetCode | `leetcode.com`、`leetcode.cn`、`leetcode-cn.com`、`leetcdn.cn` |

WARP 是出口路由；Reality 是客户端到服务器的传输安全配置，两者独立。不保证 WARP 出口可以绕过目标站点的账号限制或风控。

## 更新已有服务器的分流

适用于本项目路径 `/usr/local/etc/xray/config.json`，要求已有 WARP 代理 `127.0.0.1:40000` 正常工作：

在本机更新仓库后执行：

```powershell
scp .\my-vless-reality\install-reality.sh root@服务器公网IP:/root/install-reality.sh
ssh root@服务器公网IP 'bash /root/install-reality.sh --update-routing'
```

此模式保留 UUID、密钥、入站和其他分流规则，备份配置、验证新配置并重启 Xray；重启失败时恢复原配置。重复执行不会重复添加相同的规则。Xray 重启会短暂中断现有代理连接。

新增域名时修改脚本顶部的 `WARP_DOMAINS` 数组，提交后在服务器运行更新命令。客户端把国内域名直接连接时，请求不会到达服务器；需要 LeetCode 中国站也走 WARP，应让客户端代理这些域名。

## 保留原节点参数迁移

默认生成新凭据，仓库不包含任何真实服务器密钥。需要沿用原节点时，可通过环境变量 `UUID`、`PRIVATE_KEY`、`SHORT_ID` 私下传入；公钥由私钥推导。不要把这些变量或原服务器配置提交到仓库。其他协议参数与最初部署一致，固定端口 443、SNI/目标 `www.cloudflare.com:443`、客户端指纹 `chrome`。

## 服务管理与限制

```bash
systemctl status xray warp-svc --no-pager
systemctl restart xray
journalctl -u xray -n 50 --no-pager
cat /root/vless-reality-link.txt
```

已有 Xray 或 443 被占用时，全新安装模式退出。旧 V2Ray 配置如存在会备份，但旧服务保持原状态。已安装且正常工作的 WARP 会被复用；已安装但不可用的 WARP 不会被自动重置，以免影响现有配置。

失败安装的文件保留供排查，脚本不会自动覆盖或递归清除既有安装；不要在故障后直接删除配置，先检查日志。WARP 包版本来自官方 APT 源，后续版本变化可能需要调整 CLI 命令。此仓库不包含 ChatGPT/Instagram 等旧 V2Ray 规则，当前迁移范围是上表中的 Grok 与 LeetCode。

## 本地检查

```bash
bash -n install-reality.sh
bash tests/routing.sh
```

路由测试需要 `jq`，验证规则可重复更新、保留已有规则和默认出口、拒绝复用配置不同的 `warp` 出口。测试不会安装软件、修改系统配置或重启服务。

官方参考：[Xray 发布版本](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9)、[WARP Linux](https://developers.cloudflare.com/warp-client/get-started/linux/)、[WARP 软件源](https://pkg.cloudflareclient.com/)。
