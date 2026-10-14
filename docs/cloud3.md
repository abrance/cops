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
| `openbao/` 命名空间 | OpenBao 密钥管理，仓库第一个 helm chart 单元（期望状态 = `apps/openbao/values.yaml` 渲染官方 chart + `k8s.yaml`，CI 全自动，见 README「helm chart 单元」）；对象：StatefulSet `openbao`（OnDelete 策略）+ 内置 PVC `data-openbao-openbao-0` 10Gi + ConfigMap/ServiceAccount/ClusterRoleBinding + 2×IngressRoute + `Middleware redirect-https`；入口 `https://bao.xiaoyxq.top`，UI 在 `/ui/` |
| `demo/`（whoami deploy+svc、`IngressRoute whoami-http`/`whoami-tls`、`Middleware redirect-https`） | **临时验证用**，可作为新服务模板；不要了就 `kubectl delete ns demo` |
| `minio/` 命名空间 | 对象存储单元 `environment/minio`（CI 部署）：StatefulSet `minio` + Service + 4×IngressRoute（API 与控制台各 web/websecure 两条）+ `Middleware redirect-https`；数据在宿主机 `/opt/minio/data`（hostPath）。迁移前它是手工建的 `minio-test/`（PVC data-minio-0 + 两条手工 IngressRoute），搬迁步骤见下一小节 |
| `mysql8/` 命名空间 | 通用 MySQL 8 单元 `environment/mysql8`（CI 部署）：StatefulSet `mysql` + Service `mysql`；数据在宿主机 `/opt/mysql8/data`（hostPath），无 HTTP 接口。迁移前它是 vikunja 手工部署的 `vikunja/mysql`（PVC `data-mysql-0` + Secret `vikunja-secret`），搬迁步骤见下一小节 |
| `vikunja/` 命名空间 | 待办/项目管理单元 `apps/vikunja`（CI 部署）：ConfigMap `vikunja-config` + Deployment + Service + 2×IngressRoute + `Middleware redirect-https`；入口 `https://vikunja.xiaoyxq.top`。**无状态**：附件在 `minio/`、数据在 `mysql8/` |
| `186.244.201.55.sslip.io` 的证书 | 已签发成功，作为端到端验证证据 |

新增服务的标准三步：DNS 加 A 记录指向 `186.244.201.55` → 确认解析生效 → 照抄 demo 的两条 IngressRoute（换 Host）。**顺序不能反**，反了就是签发 404 失败，会撞 Let's Encrypt 限流（同域名每小时 5 次失败 / 每周 5 张重复证书）。

### OpenBao 特化：初始化解封与日常 Unseal

`apps/openbao`（CI 管理）只保证**部署**，`bao operator init` / `unseal` 是人工动作，原因是 root token 的产生不允许自动化。

- **init 产物**：`/opt/cops/secrets/openbao.env`（权限 600，一个 JSON：`root_token`、`unseal_keys_b64`×5、`unseal_threshold`=3）；秘密文件不入库，但也**不要只依赖这一份**——建议把内容备份进密码管理器（首次 init 时的终端打印就是给你备份用的）。
- **重新 unseal**（Pod 重建/版本升级/节点重启后必做，因为封箱状态在内存）：

  ```sh
  export KUBECONFIG=$HOME/.kube/config
  python3 -c '
  import json, subprocess
  d = json.load(open("/opt/cops/secrets/openbao.env"))
  for k in d["unseal_keys_b64"][:d["unseal_threshold"]]:
      subprocess.run(["kubectl","-n","openbao","exec","openbao-0","--","bao","operator","unseal",k], check=True)
  '
  kubectl -n openbao exec openbao-0 -- bao status | grep Sealed   # 期望 false
  ```

- **为什么没有自动化 unseal**：cloud3 没有云 KMS，transit auto-unseal 需要再养一个 OpenBao，个人环境不值得；就按上面手工解，30 秒的事。
- **为什么 readiness 探针是关的**：见 `apps/openbao/values.yaml` 的注释——chart 默认 readiness 是 `bao status`，sealed 时 exit 2 会让 Pod NotReady，开着它首次部署与每日全量重建永远红。服务可用性由 CI 的 `K8S_HEALTH`/`PUBLIC_URL` 探 `/v1/sys/seal-status`（两种状态都 200）兜底，CI 部署**不等待** unseal。
- **改配置后应用**：chart 默认 `updateStrategyType: OnDelete`，改了 `values.yaml` 后 CI 会 apply 新期望状态，但 Pod 不会自动重建，需要 `kubectl -n openbao delete pod openbao-0` 触发（然后照上面重新 unseal）。

### MinIO 特化：从 `minio-test` 迁入 `minio`（PVC → hostPath）

迁移前 MinIO 是手工部署的：ns `minio-test`、PVC `data-minio-0`（5Gi local-path）、
Secret `minio-secret`、两条只带 `websecure` 的 IngressRoute。纳入 cops 后由
`environment/minio` 管理，命名空间改为 `minio`、数据改为宿主机 `/opt/minio/data`。

顺序上**必须先处理路由冲突，再合入单元格**：新旧两套 IngressRoute 的 Host 完全相同
（`minio.186.244.201.55.sslip.io` 与 `minio-console.186.244.201.55.sslip.io`），两边
同时存在时 Traefik 的两个路由器规则优先级相等，请求会随机落到其中一边——新实例还没
同步对象，就会出现间歇性 404。建议按下列顺序执行：

1. 准备好 hostPath 目录（属主交给 k8s.yaml 的 initContainer 修，为了看不到错误先手动建也可）：

   ```bash
   sudo mkdir -p /opt/minio/data && sudo chown 1001:1001 /opt/minio/data
   ```

2. 删掉旧的两条 IngressRoute（公网 API/控制台短暂不可用，**集群内部访问不受影响**，
   vikunja 走 Service DNS 而不是公网入口）：

   ```bash
   kubectl -n minio-test delete ingressroute minio-api minio-console
   ```

3. 合入 `environment/minio` 单元格（PR1）→ CI 建出 ns `minio` 并拉起新实例。
   新实例起来后是**空库**，vikunja 此刻还指着旧的 `minio-test`，附件仍可读。

4. 在新 Pod 里把旧实例的每个 bucket 同步过来（`mc mirror` 会按需建目标 bucket）。
   在同一个集群里可以直接用 Service DNS 访问旧实例，不需要经过公网：

   ```bash
   kubectl -n minio exec minio-0 -- sh -c '
     mc alias set old http://minio.minio-test.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
     mc ls old
     for b in $(mc ls old | awk "{print \$NF}" | tr -d /); do mc mirror --preserve old/$b local/$b; done
     mc ls local'
   ```

   同步后逐桶核对对象数与总量（`mc du old/<bucket>` 对 `mc du local/<bucket>`），
   并保留一份对象清单文本（`mc ls --recursive` 输出）作为回滚凭据。

5. 把 vikunja 的 S3 endpoint 从 `http://minio.minio-test.svc.cluster.local:9000` 改成
   `http://minio.minio.svc.cluster.local:9000`（属于 PR2 的内容），重启后验一次附件下载。

6. 确认无误后再删旧资源：先 `kubectl -n minio-test get all` 留一份快照，再
   `kubectl delete ns minio-test`。`minio-secret` 随命名空间一起消失，这也是
   root 凭据必须同时进 GitHub Secrets 的原因（否则下次重建就找不回凭据）。

已知代价（有意接受）：控制台入口仍对公网开放，且登录用的就是 root 账号；root 口令与
vikunja 的 S3 AK/SK 同值（避免两侧漂移）。若要收紧，可去掉控制台的 IngressRoute 改用
`kubectl port-forward`，或给它加 Traefik basicauth 中间件。

### MySQL 与 vikunja 特化：从 `vikunja/` 的手工部署迁入 `environment/mysql8` 与 `apps/vikunja`

迁移前 vikunja 与它的数据库都是手工部署的：ns `vikunja`、StatefulSet `mysql` + PVC
`data-mysql-0`（2Gi local-path）、Secret `vikunja-secret`（DB 口令 / session 密钥 / S3 AK/SK）。
纳入 cops 后变成两个单元：

| 单元 | 命名空间 | 存储 | 说明 |
| --- | --- | --- | --- |
| `environment/mysql8` | `mysql8` | hostPath `/opt/mysql8/data` | **通用** MySQL 8，只跑 root 账号，库与账号由使用方创建；Service 名仍是 `mysql` |
| `apps/vikunja` | `vikunja` | 无（无状态） | ConfigMap + Deployment + Service + 2×IngressRoute；附件在 `minio/` |

**顺序陷阱（必须先看）**：CI 解析单元时 `apps/` 排在 `environment/` 之前。若直接合并 PR
让 CI 一次性部署，vikunja 会先被滚动到新的 DB 地址，而那时 mysql8 要么还没起来、要么是空库——
vikunja 启动会自动跑 migration，把空库建成新 schema，之后导入 dump 必然冲突。
所以先手工起 mysql8 并导数据，再让 CI 切 vikunja 的连接串：

1. 手工建 mysql8（等价于 CI 会做的事，后续 CI apply 幂等）：

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   cd /tmp && python3 -c '
   import re
   docs=[d for d in re.split(r"(?m)^---[ \t]*$", open("rendered.yaml").read()) if d.strip()]
   kinds={"Namespace","StatefulSet","Service"}
   sel=[d for d in docs if re.search(r"(?m)^kind: (\\S+)", d).group(1) in kinds]
   open("mysql8.yaml","w").write("---\\n"+"\\n---\\n".join(sel))'
   # Secret 按部署脚本的规则手工建一次（值取现有 vikunja 的 DB 口令，不落盘）
   kubectl -n mysql8 create secret generic mysql8-secrets \
     --from-literal=MYSQL_ROOT_PASSWORD="$DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
   kubectl apply -f mysql8.yaml
   kubectl -n mysql8 rollout status statefulset/mysql --timeout=300s
   ```

2. 冻结写入：`kubectl -n vikunja scale deploy/vikunja --replicas=0`
3. 导旧库（沿用迁移到 cloud3 时验证过的手法）：

   ```bash
   kubectl -n vikunja exec mysql-0 -- mysqldump -uroot -p"$OLD_ROOT_PW" \
     --single-transaction --routines --triggers --default-character-set=utf8mb4 vikunja > vikunja.sql
   ```

4. 在 mysql8 里建库建号（通用单元不预建任何库），再导入：

   ```bash
   kubectl -n mysql8 exec -i mysql-0 -- mysql -uroot -p"$DB_PASSWORD" <<'SQL'
   CREATE DATABASE IF NOT EXISTS vikunja CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER IF NOT EXISTS 'vikunja'@'%' IDENTIFIED BY '<与 SECRET_ENV 里 VIKUNJA_DATABASE_PASSWORD 同值>';
   GRANT ALL PRIVILEGES ON vikunja.* TO 'vikunja'@'%'; FLUSH PRIVILEGES;
   SQL
   kubectl -n mysql8 exec -i mysql-0 -- mysql -uroot -p"$DB_PASSWORD" vikunja < vikunja.sql
   ```

5. 校验：`users` / `projects` / `tasks` / `files` / `labels` 等表行数与旧库逐张对齐，中文取
   `hex(title)` 比对，口令哈希聚合值比对（老用户密码必须还能登录）。
6. 合并 PR2 → CI 同时 apply 两个单元：mysql8 是幂等 apply，vikunja 切到
   `mysql.mysql8.svc.cluster.local:3306` 与 `http://minio.minio.svc.cluster.local:9000`。
7. 验收：`/api/v1/info` 返回 v2.7.0、老账号可登录、附件可下载（对象 key 是 `files/<附件 id>`）、
   `deploy-k8s.sh` 的两道探活均通过。
8. 留证后再删旧资源：`mysqldump` 的 SQL、对象清单（`mc ls -r`）、旧 PVC 快照，存云主机
   `~/vikunja-backup-<日期>/`；确认后才 `kubectl -n vikunja delete sts mysql`（PVC 需显式删）、
   `kubectl delete ns minio-test`。

两点与 MinIO 一致的口径：

- **凭据只存在 GitHub Secrets 里**（`COMMON_SIMPLE_PASSWORD` 与仓库 variable `COMMON_ADMIN_USERNAME`）。
  删掉旧 ns 后本地的 `vikunja-secret` / `minio-secret` 一起消失，凭据若不入库就找不回来了。
- 本次迁移**不动行为配置**：`VIKUNJA_SERVICE_ENABLEREGISTRATION` 保持 `true`（公网实例建议改 false，
  但要单独一件事做），DNS 不动，镜像 tag 不动。

### Vikunja 特化：日常改动与升级

- 配置改 `apps/vikunja/k8s.yaml` 的 ConfigMap（非敏感）或 GitHub Secrets（DB 口令 / session 密钥 /
  S3 凭据）；`deploy-k8s.sh` 会把 ConfigMap 与 Secret 的内容哈希写进 podTemplate 注解，
  内容变才滚动，幂等。改了 `VIKUNJA_SERVICE_SECRET` 会让所有已登录 session 失效。
- 升级镜像：改 `apps/vikunja/.env` 的 `VIKUNJA_IMAGE_TAG` 后合并。启动时会自动跑 DB migration，
  **migration 不可回退**：回滚镜像不会回滚 schema，跨大版本升级前先留一份 `mysqldump`。
- 附件：对象 key 带 `files/` 前缀（`files.basepath`），手工往 MinIO 里放对象时必须带前缀，
  否则附件 404 且 `vikunja doctor` 也不会报错。
- 自带 MCP server 在 `/api/v2/mcp`（streamable HTTP），AI 客户端用它建单/查单；
  长期 token 在 vikunja 的「设置 → API Tokens」里签发，**不要**写进本仓库。

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
