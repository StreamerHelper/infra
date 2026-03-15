# StreamerHelper 构建部署架构修复设计文档

## 一、修复目标

实现用户期望的部署体验：
```bash
curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

一键启动后：
- 自动创建 `~/.streamer-helper/settings.json` 配置文件
- 拉取预构建镜像并启动所有服务

## 二、当前问题清单

### P0 - 阻塞性问题（必须修复）

| # | 问题 | 文件 | 描述 |
|---|------|------|------|
| 1 | build-and-push.sh 路径错误 | `build-and-push.sh` | 期望 `../StreamerHelper`，实际是 `../web-server` |
| 2 | Dockerfile 位置不合理 | `Dockerfile.*` | 应该在各自服务仓库内，或能正确找到构建上下文 |
| 3 | docker-entrypoint.sh 路径 | `Dockerfile.backend` | COPY 路径与实际位置不匹配 |

### P1 - 重要问题（应该修复）

| # | 问题 | 文件 | 描述 |
|---|------|------|------|
| 4 | 配置文件名不一致 | `deploy.sh` | 用户期望 `settings.json`，当前是 `config.json` |
| 5 | 缺少 CI/CD | `.github/workflows/` | 无自动构建和推送镜像 |
| 6 | Docker 组织名不统一 | 多处 | `umuoy1` vs `StreamerHelper` |

### P2 - 优化问题（建议修复）

| # | 问题 | 文件 | 描述 |
|---|------|------|------|
| 7 | 健康检查不统一 | `docker-compose.prod.yml` | 各服务健康检查方式不一致 |
| 8 | 版本管理缺失 | 多处 | 全部使用 latest，无法回滚 |
| 9 | 缺少配置模板 | - | 无 settings.json.example |

## 三、修复方案

### 3.1 仓库架构设计

采用**简化的多仓库策略**：

```
GitHub 组织: StreamerHelper
│
├── infra/                    # 部署中心仓库（当前）
│   ├── docker-compose.prod.yml
│   ├── deploy.sh
│   ├── settings.schema.json      # 配置 Schema
│   └── .github/workflows/
│       └── release.yml
│
├── backend/                  # 后端仓库（需从 web-server 分离）
│   ├── Dockerfile
│   ├── docker-entrypoint.sh
│   └── .github/workflows/
│       └── build.yml
│
└── frontend/                 # 前端仓库（需从 web 分离）
    ├── Dockerfile
    └── .github/workflows/
        └── build.yml
```

### 3.2 Docker 镜像命名

```
docker.io/streamerhelper/backend:latest
docker.io/streamerhelper/backend:v1.0.0
docker.io/streamerhelper/frontend:latest
docker.io/streamerhelper/frontend:v1.0.0
docker.io/streamerhelper/nginx:latest
```

### 3.3 部署流程

```
用户执行 curl ... | bash
        │
        ▼
┌───────────────────┐
│ 1. 检查依赖        │  Docker, jq, curl
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 2. 创建目录        │  ~/.streamer-helper/
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 3. 生成配置        │  settings.json (首次)
│                   │  .docker-env
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 4. 下载 compose    │  docker-compose.yml
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 5. 拉取镜像        │  docker compose pull
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 6. 启动服务        │  docker compose up -d
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│ 7. 健康检查        │  等待 backend healthy
└───────────────────┘
```

## 四、修复任务列表

### Phase 1: 修复构建脚本（P0）

- [ ] **Task 1.1**: 修复 `build-and-push.sh` 路径问题
- [ ] **Task 1.2**: 修复 `Dockerfile.backend` 构建上下文
- [ ] **Task 1.3**: 修复 `Dockerfile.frontend` 构建上下文
- [ ] **Task 1.4**: 确保 `docker-entrypoint.sh` 正确复制

### Phase 2: 修复部署脚本（P1）

- [ ] **Task 2.1**: 配置文件名改为 `settings.json`
- [ ] **Task 2.2**: 统一 Docker 组织名为 `streamerhelper`
- [ ] **Task 2.3**: 优化 `deploy.sh` 输出和错误处理

### Phase 3: 添加 CI/CD（P1）

- [ ] **Task 3.1**: 创建 GitHub Actions 构建工作流
- [ ] **Task 3.2**: 配置 Docker Hub 凭证

### Phase 4: 优化和完善（P2）

- [ ] **Task 4.1**: 添加 `settings.schema.json` 配置模板
- [ ] **Task 4.2**: 统一健康检查方式
- [ ] **Task 4.3**: 添加版本管理支持

## 五、文件修改清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `build-and-push.sh` | 修改 | 修复路径，支持从当前目录构建 |
| `Dockerfile.backend` | 修改 | 调整 COPY 路径 |
| `Dockerfile.frontend` | 修改 | 调整 COPY 路径 |
| `docker-compose.prod.yml` | 修改 | 统一镜像名称 |
| `deploy.sh` | 修改 | 配置文件改名为 settings.json |
| `config.schema.json` | 重命名 | → `settings.schema.json` |
| `.github/workflows/build.yml` | 新建 | CI/CD 自动构建 |
| `settings.example.json` | 新建 | 配置模板 |

## 六、向后兼容性

### 配置文件迁移

如果用户已有 `~/.streamer-helper/config.json`：
1. 检测到旧配置文件时自动迁移到 `settings.json`
2. 显示迁移提示信息

### 镜像标签

保持 `latest` 标签可用，同时支持版本标签：
- `streamerhelper/backend:latest`
- `streamerhelper/backend:v1.0.0`

## 七、测试计划

### 本地测试

```bash
# 1. 测试构建
cd infra
./build-and-push.sh test --no-cache

# 2. 测试部署（本地）
./deploy.sh --local

# 3. 验证服务
curl http://localhost/api/health
```

### 生产测试

```bash
# 在干净服务器上测试
curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

---

*文档版本: 1.0*
*创建日期: 2026-03-16*
