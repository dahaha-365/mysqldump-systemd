#!/bin/bash
# MySQL 自动备份脚本 (支持独立文件备份)
# 路径: /usr/local/bin/mysql-backup.sh
# (已包含所有错误捕获改进 + 非致命清理任务修复)

set -euo pipefail

# 加载配置文件
CONFIG_FILE="/etc/mysql-backup/backup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# 创建必要的目录
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# 全局变量
TOTAL_BACKUPS=0
FAILED_BACKUPS=0
SUCCESS_BACKUPS=0
declare -A BACKUP_RESULTS

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# 获取压缩命令和扩展名
get_compression_cmd() {
    case "$COMPRESSION" in
        gzip)
            echo "gzip -$COMPRESSION_LEVEL"
            ;;
        bzip2)
            echo "bzip2 -$COMPRESSION_LEVEL"
            ;;
        xz)
            echo "xz -$COMPRESSION_LEVEL"
            ;;
        none)
            echo "cat"
            ;;
        *)
            echo "gzip -6"
            ;;
    esac
}

get_compression_ext() {
    case "$COMPRESSION" in
        gzip)
            echo ".gz"
            ;;
        bzip2)
            echo ".bz2"
            ;;
        xz)
            echo ".xz"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 生成备份文件名
generate_backup_filename() {
    local db_name=$1
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local date=$(date '+%Y%m%d')
    local time=$(date '+%Y%M%S')

    local filename="$BACKUP_FILENAME_FORMAT"
    filename="${filename//\{dbname\}/$db_name}"
    filename="${filename//\{timestamp\}/$timestamp}"
    filename="${filename//\{date\}/$date}"
    filename="${filename//\{time\}/$time}"

    echo "${filename}.sql"
}

# 备份单个数据库 (已改进错误捕获)
backup_database() {
    local db_name=$1
    local backup_file="${BACKUP_DIR}/$(generate_backup_filename "$db_name")"
    local compression_cmd=$(get_compression_cmd)
    local compression_ext=$(get_compression_ext)

    # 创建一个临时文件来捕获 mysqldump 的 stderr
    local error_log
    error_log=$(mktemp "${BACKUP_DIR}/${db_name}_error.XXXXXX.log")

    log "INFO" "开始备份数据库: $db_name"

    # 执行 mysqldump，将 stderr 重定向到临时错误日志
    local start_time=$(date +%s)

    if mysqldump -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        $MYSQLDUMP_OPTS "$db_name" 2>"$error_log" | $compression_cmd > "${backup_file}${compression_ext}"; then

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local file_size=$(du -h "${backup_file}${compression_ext}" | cut -f1)

        log "INFO" "备份成功: $db_name -> ${backup_file}${compression_ext} (大小: $file_size, 耗时: ${duration}s)"
        BACKUP_RESULTS["$db_name"]="SUCCESS:${file_size}:${duration}s"
        ((SUCCESS_BACKUPS++))
        rm -f "$error_log" # 成功后删除空的错误日志
        return 0
    else
        log "ERROR" "备份失败: $db_name"

        # 读取错误日志并打印到主日志，过滤掉密码警告
        local error_message
        error_message=$(grep -v "Warning: Using a password on the command line" "$error_log" || true)

        if [[ -n "$error_message" ]]; then
            log "ERROR" "mysqldump 错误: $error_message"
        else
            log "ERROR" "mysqldump 错误: (未知错误，请检查MySQL日志)"
        fi

        rm -f "$error_log" # 删除临时错误日志
        rm -f "${backup_file}${compression_ext}" # 删除不完整或空的备份文件

        BACKUP_RESULTS["$db_name"]="FAILED"
        ((FAILED_BACKUPS++))
        return 1
    fi
}

# 备份所有数据库到单个文件
backup_all_databases_single() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/all_databases_${timestamp}.sql"
    local compression_cmd=$(get_compression_cmd)
    local compression_ext=$(get_compression_ext)

    # 创建一个临时文件来捕获 mysqldump 的 stderr
    local error_log
    error_log=$(mktemp "${BACKUP_DIR}/all_db_error.XXXXXX.log")

    log "INFO" "开始备份所有数据库到单个文件"

    local start_time=$(date +%s)

    # 获取要备份的数据库列表
    local db_list=""
    for db in $(get_databases); do
        db_list="$db_list --databases $db"
    done

    if mysqldump -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        $MYSQLDUMP_OPTS $db_list 2>"$error_log" | $compression_cmd > "${backup_file}${compression_ext}"; then

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local file_size=$(du -h "${backup_file}${compression_ext}" | cut -f1)

        log "INFO" "备份成功: ${backup_file}${compression_ext} (大小: $file_size, 耗时: ${duration}s)"
        ((SUCCESS_BACKUPS++))
        rm -f "$error_log" # 成功后删除空的错误日志
        return 0
    else
        log "ERROR" "备份失败"

        # 读取错误日志并打印到主日志
        local error_message
        error_message=$(grep -v "Warning: Using a password on the command line" "$error_log" || true)

        if [[ -n "$error_message" ]]; then
            log "ERROR" "mysqldump 错误: $error_message"
        else
            log "ERROR" "mysqldump 错误: (未知错误，请检查MySQL日志)"
        fi

        rm -f "$error_log" # 删除临时错误日志
        rm -f "${backup_file}${compression_ext}" # 删除不完整或空的备份文件

        ((FAILED_BACKUPS++))
        return 1
    fi
}

# 获取要备份的数据库列表
get_databases() {
    local db_list=""

    if [[ "$DATABASES" == "all" ]]; then
        db_list=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^Database$")
    else
        db_list="$DATABASES"
    fi

    # 排除指定的数据库
    for exclude_db in $EXCLUDE_DATABASES; do
        db_list=$(echo "$db_list" | grep -v "^${exclude_db}$" || true)
    done

    echo "$db_list"
}

# 清理旧备份 (针对单个数据库)
cleanup_old_backups_for_database() {
    local db_name=$1
    local keep_days=$KEEP_DAYS
    local keep_count=$KEEP_COUNT

    # 检查是否有自定义保留策略
    if [[ -n "${DATABASE_RETENTION[$db_name]:-}" ]]; then
        local retention="${DATABASE_RETENTION[$db_name]}"
        keep_days=$(echo "$retention" | cut -d: -f1)
        keep_count=$(echo "$retention" | cut -d: -f2)
    fi

    log "DEBUG" "清理数据库 $db_name 的旧备份 (保留天数: $keep_days, 保留数量: $keep_count)"

    # 按天数清理
    if [[ $keep_days -gt 0 ]]; then
        find "$BACKUP_DIR" -name "${db_name}_*.sql*" -type f -mtime +$keep_days -delete 2>/dev/null || true
    fi

    # 按数量清理
    if [[ $keep_count -gt 0 ]]; then
        ls -t "$BACKUP_DIR"/${db_name}_*.sql* 2>/dev/null | tail -n +$((keep_count + 1)) | xargs -r rm -f 2>/dev/null || true
    fi
}

# 清理所有旧备份
cleanup_old_backups() {
    log "INFO" "开始清理旧备份文件"

    if [[ "$BACKUP_MODE" == "separate" ]]; then
        # 为每个数据库单独清理
        for db in $(get_databases); do
            cleanup_old_backups_for_database "$db"
        done
    else
        # 清理单文件模式的备份
        if [[ $KEEP_DAYS -gt 0 ]]; then
            log "INFO" "删除 $KEEP_DAYS 天前的备份"
            find "$BACKUP_DIR" -name "all_databases_*.sql*" -type f -mtime +$KEEP_DAYS -delete 2>/dev/null || true
        fi

        if [[ $KEEP_COUNT -gt 0 ]]; then
            log "INFO" "保留最近 $KEEP_COUNT 个备份文件"
            ls -t "$BACKUP_DIR"/all_databases_*.sql* 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | xargs -r rm -f 2>/dev/null || true
        fi
    fi

    log "INFO" "清理完成"
}

# 刷新日志
flush_mysql_logs() {
    if [[ "$FLUSH_LOGS" == "true" ]]; then
        log "INFO" "刷新 MySQL 日志"
        # 捕获错误信息
        local error_message
        error_message=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            -e "FLUSH LOGS;" 2>&1 | grep -v "Warning: Using a password on the command line" || true)

        if [[ -n "$error_message" ]]; then
            log "WARN" "刷新日志失败"
            log "WARN" "MySQL 错误: $error_message"
            return 1 # 返回失败
        fi
    fi
    return 0 # 成功或未启用
}

# 清理二进制日志 (已改进错误捕获)
purge_binary_logs() {
    if [[ "$PURGE_BINARY_LOGS" == "true" ]] && [[ $BINARY_LOGS_KEEP_DAYS -gt 0 ]]; then
        log "INFO" "清理 $BINARY_LOGS_KEEP_DAYS 天前的二进制日志"

        # 捕获错误信息
        local error_message
        error_message=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL $BINARY_LOGS_KEEP_DAYS DAY);" \
            2>&1 | grep -v "Warning: Using a password on the command line" || true)

        if [[ -n "$error_message" ]]; then
            log "WARN" "清理二进制日志失败"
            log "WARN" "MySQL 错误: $error_message"
            return 1 # 返回失败
        fi
    fi
    return 0 # 成功或未启用
}

# 重启 MySQL
restart_mysql() {
    if [[ "$RESTART_MYSQL" == "true" ]]; then
        log "INFO" "重启 MySQL 服务"
        if systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null; then
            log "INFO" "MySQL 服务重启成功"
            sleep 5  # 等待服务完全启动
            return 0
        else
            log "ERROR" "MySQL 服务重启失败"
            return 1 # 返回失败
        fi
    fi
    return 0 # 未启用
}

# 发送邮件通知 (已改进错误捕获)
send_email_notification() {
    local status=$1
    if [[ "$ENABLE_EMAIL_NOTIFY" == "true" ]]; then
        local body="MySQL 备份任务完成\n\n"
        body+="状态: $status\n"
        body+="时间: $(date)\n"
        body+="成功: $SUCCESS_BACKUPS 个\n"
        body+="失败: $FAILED_BACKUPS 个\n"
        body+="总计: $TOTAL_BACKUPS 个\n\n"
        body+="详细信息:\n"

        for db in "${!BACKUP_RESULTS[@]}"; do
            body+="  - $db: ${BACKUP_RESULTS[$db]}\n"
        done

        body+="\n详细日志请查看: $LOG_FILE"

        # 捕获 mail 命令的错误
        local error_message
        error_message=$(echo -e "$body" | mail -s "$EMAIL_SUBJECT - $status" "$EMAIL_TO" 2>&1)

        if [[ $? -ne 0 ]]; then
            log "WARN" "发送邮件通知失败"
            log "WARN" "Mail 命令错误: $error_message"
            # 邮件发送失败不应导致脚本失败，所以我们不返回 1
        fi
    fi
}

# 生成备份报告
generate_backup_report() {
    log "INFO" "========== 备份报告 =========="
    log "INFO" "备份模式: $BACKUP_MODE"
    log "INFO" "备份统计: 成功 $SUCCESS_BACKUPS 个, 失败 $FAILED_BACKUPS 个, 总计 $TOTAL_BACKUPS 个"

    if [[ ${#BACKUP_RESULTS[@]} -gt 0 ]]; then
        log "INFO" "详细结果:"
        for db in "${!BACKUP_RESULTS[@]}"; do
            log "INFO" "  - $db: ${BACKUP_RESULTS[$db]}"
        done
    fi

    # 磁盘使用情况
    local disk_usage=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local backup_count=$(find "$BACKUP_DIR" -name "*.sql*" -type f 2>/dev/null | wc -l)
    log "INFO" "备份目录: $BACKUP_DIR"
    log "INFO" "总大小: $disk_usage, 文件数: $backup_count"
    log "INFO" "================================"
}

# 并行备份数据库
backup_databases_parallel() {
    local databases=("$@")
    local pids=()
    local running=0
    local completed=0

    for db in "${databases[@]}"; do
        # 控制并行数量
        while [[ $running -ge $PARALLEL_BACKUPS ]]; do
            # 检查已完成的进程
            local new_pids=()
            for pid in "${pids[@]}"; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    wait "$pid" || true
                    running=$((running - 1))
                    completed=$((completed + 1))
                else
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")

            # 如果还是满载，等待一下
            if [[ $running -ge $PARALLEL_BACKUPS ]]; then
                sleep 1
            fi
        done

        # 启动备份进程 (已修复: 添加 || true 以防止 set -e 退出)
        backup_database "$db" &
        pids+=($!)
        running=$((running + 1))
    done

    # 等待所有备份完成
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}

# 主函数
main() {
    log "INFO" "========== 开始 MySQL 备份任务 =========="
    log "INFO" "备份模式: $BACKUP_MODE"
    log "INFO" "压缩方式: $COMPRESSION (级别: $COMPRESSION_LEVEL)"

    # 获取数据库列表
    local databases=($(get_databases))
    TOTAL_BACKUPS=${#databases[@]}

    if [[ $TOTAL_BACKUPS -eq 0 ]]; then
        log "WARN" "没有找到需要备份的数据库"
        exit 0
    fi

    log "INFO" "发现 $TOTAL_BACKUPS 个数据库需要备份: ${databases[*]}"

    # 执行备份
    if [[ "$BACKUP_MODE" == "single" ]]; then
        # 所有数据库备份到单个文件
        backup_all_databases_single || true # 添加 || true
    else
        # 每个数据库独立备份
        if [[ $PARALLEL_BACKUPS -gt 1 ]]; then
            log "INFO" "使用并行备份 (并行数: $PARALLEL_BACKUPS)"
            backup_databases_parallel "${databases[@]}"
        else
            log "INFO" "使用顺序备份模式"
            for db in "${databases[@]}"; do
                # (已修复: 添加 || true 以防止 set -e 在单个数据库失败时终止整个脚本)
                backup_database "$db" || true
            done
        fi
    fi

    # 生成备份报告
    generate_backup_report

    # 清理旧备份
    cleanup_old_backups

    # 执行后续操作
    # (已修复: 添加 || true 以确保即使这些步骤失败，脚本也会继续发送邮件)
    flush_mysql_logs || true
    purge_binary_logs || true
    restart_mysql || true

    log "INFO" "========== MySQL 备份任务完成 =========="

    # 发送通知
    local backup_status="SUCCESS"
    [[ $FAILED_BACKUPS -gt 0 ]] && backup_status="PARTIAL_FAILED"
    [[ $SUCCESS_BACKUPS -eq 0 ]] && backup_status="FAILED"

    send_email_notification "$backup_status"

    # 返回状态码
    [[ $FAILED_BACKUPS -eq 0 ]] && exit 0 || exit 1
}

# 执行主函数
main
