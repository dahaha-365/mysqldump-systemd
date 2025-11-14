#! /bin/bash

# 定义颜色常量
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 检查用户权限
if [ "$UID" -ne 0 ]; then
    echo -e "${YELLOW}注意：此脚本需要 root 权限才能运行。${NC}"
    echo "请输入 root 密码继续安装，或按 Ctrl+C 取消。"
    # 检查 sudo 是否可用
    if command -v sudo &> /dev/null; then
        # 重新以 sudo 运行脚本
        exec sudo "$0" "$@"
    else
        echo -e "${RED}错误：未找到 sudo 命令，无法提升权限。${NC}"
        echo -e "${RED}请以 root 用户身份直接运行此脚本。${NC}"
        exit 1
    fi
fi

# 显示安装开始信息
echo -e "${GREEN}开始安装 MySQL 备份系统...${NC}"

sudo mkdir -p /etc/mysql-backup
sudo mkdir -p /var/backups/mysql
sudo mkdir -p /var/log/mysql-backup

sudo chmod 755 /var/backups/mysql
sudo chmod 755 /var/log/mysql-backup

sudo cp ./config/backup.conf /etc/mysql-backup/backup.conf
sudo chmod 600 /etc/mysql-backup/backup.conf

sudo cp ./bin/mysql-backup.sh /usr/local/bin/mysql-backup.sh
sudo chmod +x /usr/local/bin/mysql-backup.sh

sudo cp ./system/mysql-backup.service /etc/systemd/system/mysql-backup.service
sudo chmod 644 /etc/systemd/system/mysql-backup.service
sudo cp ./system/mysql-backup.timer /etc/systemd/system/mysql-backup.timer
sudo chmod 644 /etc/systemd/system/mysql-backup.timer

# 询问用户是否继续执行 systemctl 命令
echo "准备重新加载 systemd 配置并启用备份定时器..."
read -p "是否继续？(y/n): " -r confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    sudo systemctl daemon-reload
    sudo systemctl enable mysql-backup.timer
    sudo systemctl start mysql-backup.timer
    sudo systemctl status mysql-backup.timer
    echo -e "${GREEN}安装完成！MySQL 备份服务已配置并启用。${NC}"
else
    echo -e "${YELLOW}安装已取消。已复制文件，但未启用服务。${NC}"
    echo "如需手动启用，请运行："
    echo "sudo systemctl daemon-reload"
    echo "sudo systemctl enable mysql-backup.timer"
    echo "sudo systemctl start mysql-backup.timer"
    echo "sudo systemctl status mysql-backup.timer"
fi

# 配置文件修改提示
echo -e "\n=========================================="
echo -e "${YELLOW}重要提示：${NC}"
echo -e "${YELLOW}1. 请务必修改备份配置文件以适应您的环境：${NC}"
echo "   sudo vi /etc/mysql-backup/backup.conf"
echo -e "${YELLOW}2. 在配置文件中，您需要设置：${NC}"
echo "   - MySQL 数据库连接信息"
echo "   - 需要备份的数据库列表"
echo "   - 备份保留策略"
echo "   - 备份频率（如果需要修改默认值）"
echo -e "\n🌟 项目GitHub地址：https://github.com/dahaha-365/mysqldump-systemd"
echo "如有问题或建议，请访问项目页面提交 Issue 或 Pull Request。"
echo "=========================================="
