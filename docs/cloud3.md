# cloud3 环境维护（k3s 单机）

本文件记录 `cloud3` 云主机上**人工做过的所有重要操作**，用于故障后按顺序重建。所有内容都在主机上手工执行过，不是设想。

> 与 `deploy.sh` 那套（GitHub Actions 推到旧云主机的 Docker Compose 流程）**无关**：cloud3 是独立的 k3s 主机，目前不接入本仓库的 CD 流程。

## 一、主机信息

| 项 | 值 |
| --- | --- |
| 公网 IP | `186.244.201.55`（= 出网 IP，1:1 NAT） |
| 内网 IP | `10.0.52.2` |
| 系统 | Ubuntu 24.04.1 LTS，内核 6.8.0-48 |
| 主机名 | `ser539375215934`（未改，`\h` 显示的是它） |
| 规格 | 16 GB 内存 / 68 GB 磁盘（用约 5%） |
| SSH | `ssh cloud3`（本机 `~/.ssh/config` 别名），端口 **35776**，密钥 `~/.ssh/id_rsa_xiaomi_host`，用户 `xiaoy`（sudo 组，**NOPASSWD**） |
| 入口 | 80 / 443 / 6443 / 10250 对公网开放；8472、2379、NodePort 段关闭 |

## 二、已装软件

| 软件 | 版本 / 位置 | 安装方式 |
| --- | --- | --- |
| k3s | `v1.37.0+k3s1`（bb7cf065，containerd 2.3.4），`/usr/local/bin/k3s` | `curl -sfL https://get.k3s.io \| sudo INSTALL_K3S_VERSION=v1.37.0+k3s1 sh -` |
| Helm | `v3.22.0+g144ca65`，`/usr/local/bin/helm` | 官方 `get-helm-3` 脚本 |
| Traefik | 3.7.13（chart `41.4.2+up41.4.0`，appVersion v3.7.12） | k3s 自带 HelmChart，**不是手工装的** |
| Gateway API CRD | chart `1.6.103`（规范 v1.6.1） | k3s 自带，仅 CRD，provider 未启用 |
| tmux / git / curl / vim / htop | 系统包 | 无需处理 |
| Docker | **未安装**（刻意不装，避免 iptables FORWARD DROP 破坏 k3s 网络） | — |

## 三、改过的配置（逐条都是人工动作）

### 1. SSH 免密登录
`/etc/ssh/sshd_config` 第 122 行 `PubkeyAuthentication no` → `yes`，然后 `systemctl restart sshd`。**装机默认是 no，密钥登录一直不通就是这条。**

### 2. 登录 shell 换成 bash（无需 root）
passwd 里的登录 shell 是 `/bin/sh`(dash)，`~/.bashrc` 不会被加载。**`chsh` 没执行过**，走的是 `~/.profile` 追加方案：

```sh
# ~/.profile 末尾
case $- in
  *i*) [ -n "$BASH_VERSION" ] || exec /bin/bash ;;
esac
```

### 3. `~/.bash_aliases`（Ubuntu 自带 `~/.bashrc` 会自动 source）
- 别名：`ls --color`、`ll`、`la`、`grep --color`、`df -h`、`free -m`、`ports`（`ss -tulpn`）
- 历史：`histappend`、`HISTCONTROL=ignoreboth:erasedups`、5 万条、上箭头前缀搜索
- PS1：`用户@主机:路径(黄色 git 分支)$`
- 环境变量：`XIAOY_EMAIL=1103098607@qq.com`、`XIAOY_ROOT_DOMAIN=xiaoyxq.top`、`XIAOY_DNS_PROVIDER=tencentcloud`、`export KUBECONFIG=$HOME/.kube/config`

### 4. 其他 shell 配置
- `~/.inputrc`：Tab 补全忽略大小写、不响铃
- `~/.tmux.conf`：鼠标、5 万行回滚、窗口从 1 开始编号、`prefix r` 重载

### 5. k3s 相关
- **对外 IP 加进服务端证书 SAN**（否则公网访问 6443 报 `x509: certificate is valid for ... not 186.244.201.55`）：
  `/etc/rancher/k3s/config.yaml.d/10-tls-san.yaml`
  ```yaml
  tls-san:
    - 186.244.201.55
  ```
  加完 `systemctl restart k3s`，动态证书会自动重签并带上该 IP。`/etc/rancher/k3s/config.yaml` 只有 `node-ip: 10.0.52.2`（k3s 自己写的）。
- **Traefik 开启 Let's Encrypt**（`kube-system/HelmChartConfig traefik`，不要用 `helm upgrade` 动 k3s 托管的 release）：
  ```yaml
  spec:
    valuesContent: |-
      additionalArguments:
        - "--certificatesresolvers.letsencrypt.acme.email=1103098607@qq.com"
        - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
        - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      persistence:
        enabled: true
        size: 128Mi
  ```
  改完 k3s 的 helm-controller 会自动重跑 `helm-install-traefik` 并滚动重启 Traefik。**persistence 必须开**：不开的话 `acme.json` 在 emptyDir，重启丢证书、反复重签会撞 Let's Encrypt 限流。
- **kubeconfig 给非 root 用户用**：`sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && chown xiaoy:xiaoy ~/.kube/config && chmod 600`。注意 k3s 轮换客户端证书后这份拷贝会失效，重新复制即可。

### 6. 公网入口 / 证书（当前生效方案）
- 入口：k3s 自带 Traefik（servicelb/klipper 在 80/443 上做 DNAT；主机上没有监听进程，`ss` 看不到是正常的）
- 证书：Traefik 内置 ACME + HTTP-01，`acme.json` 落在 PVC `kube-system/traefik`（128 Mi，local-path），90 天自动续期
- **一个子域名 = 两条 IngressRoute**：`entryPoints: [web]` 不带 tls（挂 `redirectScheme` 中间件跳 https）+ `entryPoints: [websecure]` 带 `tls.certResolver: letsencrypt`
- **一条 IngressRoute 同时写 `[web, websecure]` + `tls` 是错的**：Traefik v3 只生成 websecure 路由器，80 端口 404，而且 HTTP-01 挑战同样 404

## 四、当前集群里的对象

| 对象 | 说明 |
| --- | --- |
| `kube-system/HelmChartConfig traefik` | 上面的 ACME + persistence 配置 |
| `kube-system/pvc traefik` | 存 `acme.json` |
| `cops/` 命名空间 | 从旧主机迁入的单元，全部由 CI 部署（见第八节）：`model-ocr`（Deployment+Service+2×IngressRoute，无状态）、`model-logcluster`（同上 + PVC `model-logcluster-state` 2Gi）、共享 `Middleware redirect-https` |
| `demo/`（whoami deploy+svc、`IngressRoute whoami-http`/`whoami-tls`、`Middleware redirect-https`） | **临时验证用**，可作为新服务模板；不要了就 `kubectl delete ns demo` |
| `186.244.201.55.sslip.io` 的证书 | 已签发成功，作为端到端验证证据 |

新增服务的标准三步：DNS 加 A 记录指向 `186.244.201.55` → 确认解析生效 → 照抄 demo 的两条 IngressRoute（换 Host）。**顺序不能反**，反了就是签发 404 失败，会撞 Let's Encrypt 限流（同域名每小时 5 次失败 / 每周 5 张重复证书）。

## 五、网络事实

- `docker.io` 与 `ghcr.io` 都能直连：token/manifest/blob 全通，实测 6.9 / 7.9 MB/s，**不需要镜像加速器，也不需要旧云主机那套 `ghcr.chenby.cn` 替换**
- 80/443 上的 404 是 Traefik 默认页，不是故障
- 未认证访问已确认被拦：`https://186.244.201.55:6443/api` → 401，kubelet 10250 → 401

## 六、故障后重建顺序

1. 云厂商侧：放行 35776(SSH) / 80 / 443 / 6443 / 10250
2. 建 `xiaoy` 用户并入 sudo 组，配 NOPASSWD
3. 本机 `ssh-copy-id -p 35776`，确认 `ssh cloud3` 免密；**若不通先查 `/etc/ssh/sshd_config` 的 `PubkeyAuthentication`**
4. 写 `~/.profile` 的 exec bash、`~/.bash_aliases`、`~/.inputrc`、`~/.tmux.conf`
5. 装 k3s：`curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=v1.37.0+k3s1 sh -`
6. 加 `config.yaml.d/10-tls-san.yaml` → `systemctl restart k3s`
7. apply 第三节的 `HelmChartConfig traefik`，等 PVC Bound、Traefik 的 args 里出现 acme 参数
8. 拷 kubeconfig 到 `~/.kube/config`（600），装 helm
9. 建业务命名空间 + Service + 两条 IngressRoute
10. 验签：`curl -o /dev/null -w '%{http_code} %{ssl_verify_result}' https://<域名>/` 期望 `200 0`；`openssl s_client -servername <域名> -connect 186.244.201.55:443 | openssl x509 -noout -issuer` 期望 Let's Encrypt

## 七、坑清单（都实际踩过）

| 现象 | 原因 / 处理 |
| --- | --- |
| 密钥登录一直要密码 | `PubkeyAuthentication no`（默认值），改 yes |
| `kubectl` 忽略 `~/.kube/config` | 本机/主机的 `kubectl` 是 k3s 二进制，不带 `--kubeconfig` 时读 `/etc/rancher/k3s/k3s.yaml`；用 `export KUBECONFIG=$HOME/.kube/config` |
| 合并 kubeconfig 后证书坏掉（`unable to load root certificates`） | `kubectl config view -o json` 会输出 `DATA+OMITTED` 抹掉证书；要用 `kubectl config view --raw --flatten`，且两份配置的 cluster/user 不能都叫 `default`（先 `rename-context`） |
| Let's Encrypt 报 `invalidContact ... forbidden domain "example.com"` | ACME email 不能用 example.com，填真实邮箱 |
| HTTP-01 挑战 404 / `invalid authorization: 403` | 见第三节第 6 条：路由必须拆两条 |
| 改完 HelmChartConfig 立即签证书失败 | Traefik 滚动重启期间的挑战请求被旧 Pod 接走；等 `rollout status` 完成再试，或 `rollout restart` 重来 |
| `visudo` 相关 | 自定义 sudo 规则放 `/etc/sudoers.d/`，文件名**不能带点**，权限 440，改完 `visudo -c` |

## 八、接入 cops CD

cloud3 作为第二台主机接入 `cops` 的 CD（多主机 + k8s 部署模式），机制细节见仓库根
[README.md](../README.md) 的「k8s 部署模式」与 [cloud3-k8s-cd-design.md](cloud3-k8s-cd-design.md)。

登记方式：仓库根 `hosts.yaml` 里的 `cloud3` 段声明 `drivers: k8s` 与五个 Secret 名字；
单元在 `app.conf` 里写 `DEPLOY_TARGET=cloud3`。CI 侧需要的 Secret：

| Secret | 值 |
| --- | --- |
| `CLOUD3_DEPLOY_HOST` | `186.244.201.55` |
| `CLOUD3_DEPLOY_USER` | `xiaoy` |
| `CLOUD3_DEPLOY_SSH_KEY` | **CI 专用私钥**（`ssh-keygen -t ed25519 -f cops-deploy-cloud3 -C cops-ci`），公钥追加到主机的 `~/.ssh/authorized_keys` |
| `CLOUD3_DEPLOY_PORT` | `35776` |
| `CLOUD3_DEPLOY_KNOWN_HOSTS` | 主机公钥（可选；缺省时 CI 用 `ssh-keyscan` 临时获取） |

主机侧前置（一次性，**漏了会以 `mkdir: cannot create directory '/opt/cops': Permission denied` 失败**）：

```bash
sudo mkdir -p /opt/cops/secrets
sudo chown -R xiaoy:xiaoy /opt/cops     # CI 以 xiaoy 身份同步单元目录与密钥文件
```

部署时发生的事：CI 在 runner 侧用 `scripts/render-k8s.py` 把 `k8s.yaml` + `.env` 渲染成
`rendered.yaml` → 目录同步到 `/opt/cops/<scope>/<name>/` → 执行 `scripts/deploy-k8s.sh`
（`kubectl apply` → `rollout status` → 从主机 curl Service 的 ClusterIP 探活 → 可选探公网入口）。

两条与云主机环境强相关的注意事项：

- **kubeconfig**：`deploy-k8s.sh` 通过 `ssh host "bash -s"` 执行，非交互 shell 不会加载
  `~/.bash_aliases` 里的 `KUBECONFIG`，所以脚本里显式指向 `~/.kube/config`（见第三节第 5 条）。
- **k3s 托管的 Helm release 不要动**：`traefik` / `traefik-crd` / `gateway-api-crd` 由 k3s 的
  HelmChart 控制器管理，`helm upgrade` 会与其抢同一份 release。

## 九、未做 / 待决策

- **Gateway API 暂不启用**（CRD 已随 k3s 装好，但 provider 关闭）。原因：Gateway API 的 listener TLS 只能引用 Secret，Traefik 内置 ACME 挂不上去，等于要额外引入 cert-manager + 腾讯云 DNS webhook。触发重新评估：多人/多团队自助开通子域名、需要 TCP/UDP/gRPC、需要标准化灰度语义、或想换掉 Traefik。
- 泛域名证书（`*.xiaoyxq.top`）未启用。方案：Traefik ACME DNS-01 + lego 的 `tencentcloud` provider（`TENCENTCLOUD_SECRET_ID` / `TENCENTCLOUD_SECRET_KEY`），好处是以后加服务连 DNS 都不用动。密钥只放 k8s Secret，**不入库**。
- `demo` 命名空间是验证残留（whoami + sslip.io 证书），可按需删除：`kubectl delete ns demo`。
- 旧主机的 `model-logcluster_state` 卷按计划保留一周（到 2026-10-02）后再删；迁移时的状态快照备份在 cloud3 的 `/opt/cops/backup/model-logcluster-state-2026-09-25.tgz`（sha256 `377f2e7b…`）。
