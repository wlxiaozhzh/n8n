# 社区节点离线维护与稳态手册

为避免 n8n 在生产环境中因为缺少社区节点依赖而无法启动，建议在每次导入/更新离线包时按照下面流程操作。所有步骤都在仓库根目录执行。

## 1. 同步离线包

```bash
./scripts/sync-community-nodes.sh /path/to/community-nodes-YYYYMMDD.tar.gz
```

脚本会：
- 自动备份 `data/custom` 与 `data/nodes`（带时间戳目录），方便快速回滚；
- 将归档中的 `package.json / package-lock.json / node_modules` 拷贝到两个数据目录，并跳过会导致崩溃的 `pkce-challenge`；
- 建立 `data/custom/<package>` 指向 `data/custom/node_modules/<package>` 的符号链接，保证 n8n 能正确加载；
- 通过 docker 运行一次 Node 脚本，生成最新的社区节点元数据并刷新 Postgres 的 `installed_packages / installed_nodes`；
- 把生成的 `packages_metadata.json` 和 `install_packages.sql` 归档到 `community_nodes_metadata/` 方便审计。

> 如果没有显式传参，脚本会自动寻找仓库内最新的 `community-nodes-*.tar.gz`。

## 2. 启动/重启容器

同步完成后执行：

```bash
docker compose -f docker-compose.yml.bak restart n8n n8n-worker-1 n8n-worker-2 n8n-worker-3
```

容器日志应出现 `n8n ready on ::, port 5678`，且不会再提示 `detected that some packages are missing`。若仍有报错，请先运行下一节的健康检查脚本定位差异。

## 3. 健康检查

```bash
./scripts/check-community-nodes.sh
```

输出包含：
- 当前磁盘上存在的社区包列表；
- 数据库已登记但磁盘缺失的包（需重新同步）；
- 磁盘存在但数据库没有登记的包（需执行上面的同步脚本）；
- 对 `pkce-challenge` 的额外提示，避免再次因为错误版本而导致主服务崩溃。

## 4. 常见加固建议

- **凭据**：部署新节点后及时在 UI 中创建对应 Credential（如 `pipefyApi`、`dingtalkApi`），否则日志会持续出现 Unknown credential 提示。
- **备份**：保留 `data/custom_backup_*/` 和 `data/nodes_backup_*/` 的最近两个版本。当部署失败时直接回滚备份目录再重启容器即可。
- **环境变量**：若无需在代码节点中访问宿主机环境变量，请在 Compose 中设置 `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`，并将 `N8N_GIT_NODE_DISABLE_BARE_REPOS=true` 以消除安全告警。
- **定期验证**：升级 n8n 或社区节点前，先在测试环境执行 `sync-community-nodes.sh`，确认脚本能顺利跑完后再在生产环境实施。

按照以上流程操作，可最大程度降低“无法登陆/服务启动失败”的概率，确保生产实例稳定运行。
