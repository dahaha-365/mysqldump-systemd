# MySQL 自动备份系统安装指南
<img width="1007" height="447" alt="image" src="https://github.com/user-attachments/assets/1dd1ac3e-9c8f-45ea-9ee5-cf94249b2057" />

> [!CAUTION]
> 安装前请认真阅读此文档，确保您已了解 MySQL 权限系统和备份原理。
> 
> 没有基础的用户不建议直接安装此系统。
> 
> 安装前请备份好数据库，以防意外发生。
> 
> 安装完成后，请检查 `/etc/mysql-backup/backup.conf` 配置文件，确保数据库连接配置正确。

这个系统是通过 mysqldump 工具来备份 MySQL 数据库的。对于平时接外快的小项目是比较方便的，但是对于大项目还是建议使用专业的备份工具。

## 一、准备工作

### 1. 创建 MySQL 备份用户

```bash
# 登录 MySQL
mysql -u root -p

# 创建备份专用用户
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'your_strong_password';

# 授予必要的权限
GRANT SELECT, RELOAD, BINLOG_ADMIN, LOCK TABLES, PROCESS, REPLICATION CLIENT, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup_user'@'localhost';

# 刷新权限
FLUSH PRIVILEGES;

# 退出
EXIT;
```

### 2. 创建必要的目录

```bash
# 创建配置目录
sudo mkdir -p /etc/mysql-backup

# 创建备份目录
sudo mkdir -p /var/backups/mysql

# 创建日志目录
sudo mkdir -p /var/log/mysql-backup

# 设置权限
sudo chmod 755 /var/backups/mysql
sudo chmod 755 /var/log/mysql-backup
```

## 二、安装文件

> [!TIP]
> 直接运行 `install.sh` 脚本即可完成安装。

### 1. 复制配置文件

```bash
# 创建配置文件
sudo nano /etc/mysql-backup/backup.conf
# 将配置文件内容粘贴进去,并根据实际情况修改

# 设置配置文件权限(保护密码)
sudo chmod 600 /etc/mysql-backup/backup.conf
```

### 2. 安装备份脚本

```bash
# 创建备份脚本
sudo nano /usr/local/bin/mysql-backup.sh
# 将脚本内容粘贴进去

# 设置执行权限
sudo chmod +x /usr/local/bin/mysql-backup.sh
```

### 3. 安装 systemd 服务文件

```bash
# 创建服务文件
sudo nano /etc/systemd/system/mysql-backup.service
# 将服务文件内容粘贴进去

# 创建定时器文件
sudo nano /etc/systemd/system/mysql-backup.timer
# 将定时器文件内容粘贴进去
```

## 三、配置说明

### 主要配置项

**数据库配置:**
- `DATABASES`: 指定要备份的数据库,多个用空格分隔,或使用 "all" 备份所有
- `EXCLUDE_DATABASES`: 排除不需要备份的数据库

**备份模式:**
- `BACKUP_MODE`: 
  - `separate`: 每个数据库单独备份为一个文件 (推荐)
  - `single`: 所有数据库备份到一个文件

**备份保留策略:**
- `KEEP_DAYS`: 按天数保留备份(0表示不限制)
- `KEEP_COUNT`: 按数量保留备份(0表示不限制)
- `DATABASE_RETENTION`: 为每个数据库单独设置保留策略(仅 separate 模式)

**压缩设置:**
- `COMPRESSION`: gzip(推荐), bzip2, xz, none
- `COMPRESSION_LEVEL`: 1-9,数字越大压缩率越高但速度越慢

**并行备份:**
- `PARALLEL_BACKUPS`: 并行备份的数据库数量(1=顺序执行)

**备份后操作:**
- `RESTART_MYSQL`: 是否重启 MySQL(true/false)
- `FLUSH_LOGS`: 是否刷新日志(true/false)
- `PURGE_BINARY_LOGS`: 是否清理二进制日志(true/false)

**定时设置 (在 timer 文件中):**
- 修改 `OnCalendar` 来设置备份时间
- 示例已在 timer 文件中提供

## 四、启动和管理

### 1. 重载 systemd 配置

```bash
sudo systemctl daemon-reload
```

### 2. 测试备份脚本

```bash
# 手动执行一次备份测试
sudo /usr/local/bin/mysql-backup.sh

# 检查日志
sudo tail -f /var/log/mysql-backup/backup.log

# 检查备份文件
ls -lh /var/backups/mysql/
```

### 3. 启用和启动定时器

```bash
# 启用定时器(开机自启)
sudo systemctl enable mysql-backup.timer

# 启动定时器
sudo systemctl start mysql-backup.timer

# 查看定时器状态
sudo systemctl status mysql-backup.timer

# 查看所有定时器
sudo systemctl list-timers --all | grep mysql-backup
```

### 4. 手动执行备份

```bash
# 手动触发一次备份
sudo systemctl start mysql-backup.service

# 查看服务状态
sudo systemctl status mysql-backup.service
```

## 五、日常管理

### 查看备份状态

```bash
# 查看定时器下次执行时间
systemctl list-timers mysql-backup.timer

# 查看最近的日志
sudo journalctl -u mysql-backup.service -n 50

# 查看实时日志
sudo journalctl -u mysql-backup.service -f

# 查看备份日志文件
sudo tail -f /var/log/mysql-backup/backup.log
```

### 查看备份文件

```bash
# 列出所有备份
ls -lh /var/backups/mysql/

# 按时间排序
ls -lht /var/backups/mysql/

# 查看特定数据库的备份
ls -lht /var/backups/mysql/database_name_*

# 查看备份文件大小统计
du -sh /var/backups/mysql/*

# 按数据库分组统计
for db in database1 database2; do
    echo "=== $db ==="
    ls -lht /var/backups/mysql/${db}_* | head -5
    du -sh /var/backups/mysql/${db}_*
done
```

### 停止和禁用

```bash
# 停止定时器
sudo systemctl stop mysql-backup.timer

# 禁用定时器
sudo systemctl disable mysql-backup.timer
```

## 六、恢复数据

### 恢复单个数据库

```bash
# 解压备份文件(gzip)
gunzip /var/backups/mysql/database_name_20250101_020000.sql.gz

# 恢复数据库
mysql -u root -p database_name < /var/backups/mysql/database_name_20250101_020000.sql
```

### 恢复所有数据库

```bash
# 解压
gunzip /var/backups/mysql/all_databases_20250101_020000.sql.gz

# 恢复
mysql -u root -p < /var/backups/mysql/all_databases_20250101_020000.sql
```

## 七、故障排查

### 检查服务失败原因

```bash
# 查看详细错误信息
sudo journalctl -u mysql-backup.service -xe

# 查看完整日志
sudo journalctl -u mysql-backup.service --no-pager

# 检查脚本语法
bash -n /usr/local/bin/mysql-backup.sh
```

### 常见问题

1. **权限问题**: 确保脚本有执行权限,目录有写权限
2. **MySQL 连接失败**: 检查配置文件中的用户名密码
3. **磁盘空间不足**: 检查备份目录空间,调整保留策略
4. **备份时间过长**: 调整 service 文件中的 TimeoutStartSec

## 八、高级配置

### 为不同数据库设置不同的保留策略

在配置文件中:

```bash
# 启用 separate 模式
BACKUP_MODE="separate"

# 全局默认保留策略
KEEP_DAYS=7
KEEP_COUNT=10

# 为重要数据库设置更长的保留期
declare -A DATABASE_RETENTION
DATABASE_RETENTION["production_db"]="30:50"    # 保留30天或最近50个
DATABASE_RETENTION["important_db"]="60:100"   # 保留60天或最近100个
DATABASE_RETENTION["test_db"]="3:5"           # 测试库只保留3天或5个
```

### 配置邮件通知

> [!NOTE]
> 此处以QQ邮箱为例，其他邮箱配置类似。SMTP服务需要自行在邮箱设置中开启。

> [!TIP]
> 如果遇到邮件发送失败问题，检查postfix服务是否运行正常。


```bash
# 安装 mailutils
sudo apt-get install mailutils  # Debian/Ubuntu
sudo yum install mailx          # CentOS/RHEL

# 配置postfix发送邮件
sudo apt-get install postfix  # Debian/Ubuntu
sudo yum install postfix      # CentOS/RHEL

# 修改 postfix 配置 smtp，以 QQ 邮箱为例
sudo vi /etc/postfix/main.cf

# 配置中继服务器（QQ 邮箱 SMTP 地址）
relayhost = [smtp.qq.com]:587

# 启用 SASL 认证（用于 QQ 邮箱登录验证）
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd

# 启用 TLS 加密（QQ 邮箱要求加密连接）
smtp_use_tls = yes
smtp_tls_CAfile = /etc/pki/tls/certs/ca-bundle.crt
smtp_tls_session_cache_database = btree:/var/lib/postfix/smtp_tls_session_cache

# 保存并退出

# 配置 QQ 邮箱登录密码
echo "[smtp.qq.com]:587 admin@example.com:授权码" | sudo tee -a /etc/postfix/sasl_passwd

# 保存并退出

# 生成 postfix 密码数据库
sudo postmap /etc/postfix/sasl_passwd

# 设置 postfix 密码数据库权限
sudo chown root:root /etc/postfix/sasl_passwd.db /etc/postfix/sasl_passwd
sudo chmod 600 /etc/postfix/sasl_passwd.db /etc/postfix/sasl_passwd

# 重启 postfix 服务
sudo systemctl restart postfix

# 在配置文件中启用邮件通知
ENABLE_EMAIL_NOTIFY=true
EMAIL_FROM="admin@example.com"
EMAIL_TO="admin@example.com"
```

### 并行备份提高速度

```bash
# 在配置文件中设置
PARALLEL_BACKUPS=3  # 同时备份3个数据库

# 注意: 并行数不要超过 CPU 核心数和磁盘 I/O 能力
```

### 按数据库组织备份目录

修改脚本中的备份路径部分:

```bash
# 在 backup_database() 函数中取消注释:
mkdir -p "${BACKUP_DIR}/${db_name}"
backup_file="${BACKUP_DIR}/${db_name}/$(generate_backup_filename "$db_name")"

# 这样每个数据库的备份会存储在独立的子目录中
# /var/backups/mysql/
#   ├── database1/
#   │   ├── database1_20250101_020000.sql.gz
#   │   └── database1_20250102_020000.sql.gz
#   └── database2/
#       ├── database2_20250101_020000.sql.gz
#       └── database2_20250102_020000.sql.gz
```

### 多实例备份

如需备份多个 MySQL 实例,可以:
1. 复制配置文件(如 backup-instance2.conf)
2. 复制 service 和 timer 文件(如 mysql-backup-instance2.service)
3. 修改配置指向不同的实例和备份目录

### 远程备份

```bash
# 备份完成后同步到远程服务器
# 在脚本末尾添加:
# rsync -avz /var/backups/mysql/ user@remote-server:/backup/mysql/
```

## 九、安全建议

1. **保护配置文件**: `chmod 600 /etc/mysql-backup/backup.conf`
2. **使用专用备份用户**: 不要使用 root 用户
3. **定期测试恢复**: 确保备份文件可用
4. **异地备份**: 将备份同步到其他服务器
5. **监控备份任务**: 设置告警通知
6. **加密敏感备份**: 对重要数据库备份进行加密

---

## 快速开始命令汇总

```bash
# 1. 创建目录
sudo mkdir -p /etc/mysql-backup /var/backups/mysql /var/log/mysql-backup

# 2. 安装文件 (按上述步骤操作)

# 3. 设置权限
sudo chmod 600 /etc/mysql-backup/backup.conf
sudo chmod +x /usr/local/bin/mysql-backup.sh

# 4. 重载并启动
sudo systemctl daemon-reload
sudo systemctl enable mysql-backup.timer
sudo systemctl start mysql-backup.timer

# 5. 验证
sudo systemctl status mysql-backup.timer
sudo systemctl list-timers mysql-backup.timer
```
