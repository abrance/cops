# 服务负责人文档

本目录面向**各服务仓库的负责人**：如何把服务接入 `cops`、日常怎么变更、出问题怎么处理。

## 阅读路径

| 你的情况 | 先读 |
| --- | --- |
| 第一次把服务接入 | [onboarding.md](onboarding.md) |
| 已接入，想知道怎么写才不出问题 | [best-practices.md](best-practices.md) |
| 想查镜像源和配置约定 | [knowledge.md](knowledge.md) |
| 部署失败或容器异常 | [troubleshooting.md](troubleshooting.md) |
| 要维护 / 重建 cloud3（k3s 主机） | [cloud3.md](cloud3.md) |
| 想先理解整体怎么运转 | 本文「一图看懂」 |

## 一图看懂

```text
你的服务仓库                     cops 仓库                        云主机
─────────────                   ─────────                       ──────
1. 构建镜像                                                    
   推 vX.Y.Z                     
        │                        
        └──► ghcr.chenby.cn/abrance/<服务>:vX.Y.Z  (仓库约定镜像源)
                                      ▲
                                      │ 引用镜像 tag
                                      │
                         apps/<应用>/{compose.yaml,.env,app.conf}          ← 应用
                         environment/<组件>/{compose.yaml,.env,app.conf}   ← 应用依赖的环境组件
                                      │
                                      │ 开 PR（只校验编排，不部署）
                                      │ 合入 main
                                      ▼
                              GitHub Actions ──SSH──► 同步 /opt/cops/apps/<应用>
                                                     同步 /opt/cops/environment/<组件>
                                                     拉镜像 → up -d → 等健康 → 探测接口
                                                         │
                                                         └── 数据保留在
                                                             /opt/<服务>/ 或命名卷
```

## 你需要记住的五件事

1. **仓库是公开的**。任何提交全网可见，密钥绝不可入库。
2. **你只改 `apps/<你的服务>/` 或 `environment/<你的组件>/`**，构建、部署、健康检查由 CI 完成。环境组件是「应用依赖的中间件」，规则与 apps 一致但不得反向依赖 apps。
3. **不要在云主机手工改 `/opt/cops`**，每次部署会全量覆盖该目录。
4. **数据不随仓库走**。用命名卷或宿主机绝对路径挂载，删容器不丢数据。
5. **任何变更走分支 + PR**；PR 只校验编排，合入 `main` 才部署。

## 速查

| 事项 | 位置 / 命令 |
| --- | --- |
| 应用的期望状态 | `apps/<服务>/`（compose.yaml、.env、app.conf） |
| 环境组件的期望状态 | `environment/<组件>/`（同上三个文件） |
| 应用元数据与健康检查 | `apps/<服务>/app.conf`、`environment/<组件>/app.conf` |
| 部署脚本 | `scripts/deploy.sh`（在云主机执行，参数 `<名字> <apps\|environment>`） |
| 部署流水线 | `.github/workflows/deploy.yml` |
| 云主机部署目录 | `/opt/cops/apps/<服务>`、`/opt/cops/environment/<组件>` |
| 云主机密钥文件 | `/opt/cops/secrets/<名字>.env`（由 CI 写入，权限 600） |
| 强制重新部署 | Actions → Deploy → Run workflow，`app` 填 `<名字>` 或 `<scope>/<名字>` |
| 查看部署状态 | `Actions` → 选择 run，或云主机上 `docker compose -f /opt/cops/<scope>/<名字>/compose.yaml ps` |

## 责任边界

| 你负责 | CI / 平台负责 |
| --- | --- |
| 镜像的构建与发布、镜像源登记 | 拉取镜像、重建容器 |
| `apps/<服务>/` 或 `environment/<组件>/` 下的期望状态 | 同步文件到云主机 |
| 声明健康检查、必需变量、密钥名 | 下发密钥、等待健康、失败回滚判定 |
| 数据目录与持久化设计 | 编排校验、变更识别、定时纠偏 |
| 环境组件与应用的依赖设计（顺序不保证） | 按变更范围只部署受影响单元 |
