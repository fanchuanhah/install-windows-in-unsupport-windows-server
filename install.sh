#!/bin/bash
# ==================================================
# 综合脚本：CentOS 8 专用 - 自动部署 Windows 并清除密码
# 功能：修复 DNF 源 -> 安装 chntpw -> 下载/写入 Windows 镜像
#      -> 扩展 NTFS 分区 -> 挂载分区 -> 自动清除密码
# ==================================================
# 修复版本：增强了 ntfs-3g 安装可靠性，确保 ntfsresize/ntfsfix 可用
# ==================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
print_header(){ echo ""; echo "========================================="; echo -e "${BLUE}  $1${NC}"; echo "========================================="; }

# ---------- 系统检测：仅允许 CentOS 8 / Stream 8 ----------
check_centos8() {
    if [[ -f /etc/centos-release ]]; then
        local release=$(cat /etc/centos-release)
        if [[ "$release" =~ "CentOS Stream" ]] && [[ "$release" =~ "8" ]]; then
            print_info "检测到 CentOS Stream 8"
        elif [[ "$release" =~ "CentOS Linux release 8" ]]; then
            print_info "检测到 CentOS 8"
        else
            print_error "此脚本仅支持 CentOS 8 / CentOS Stream 8"
            echo "当前系统: $release"
            exit 1
        fi
    else
        print_error "未检测到 CentOS 系统"
        exit 1
    fi
}

# ==================== 新增：智简魔方环境确认 ====================
confirm_magiccube() {
    echo ""
    print_header "使用环境确认"
    print_warning "请确保以下条件："
    echo "  ⚠️  1. 你使用的服务器提供商使用的是智简魔方面板"
    echo "  ⚠️  2. 你的服务器没有提供 Windows 安装选项"
    echo "     （有的话请直接使用服务器面板里的重装 Windows）"
    echo "  ⚠️  3. 本脚本并不能保证 100% 安装成功，可能需要自行调试"
    echo "  ⚠️  4. 本脚本仅供学习交流使用，作者不承担任何责任"
    echo ""
    read -p "确认继续？输入 y 继续: " confirm
    if [[ "$confirm" != "y" ]]; then
        print_info "操作已取消"
        exit 0
    fi
}

# 检查 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行！"
        exit 1
    fi
}

# 列出磁盘并选择
select_disk() {
    echo "========================================="
    echo "   可用的磁盘列表"
    echo "========================================="
    disks=($(lsblk -d -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}'))
    if [[ ${#disks[@]} -eq 0 ]]; then
        print_error "未找到任何磁盘"
        exit 1
    fi
    for i in "${!disks[@]}"; do
        disk="${disks[$i]}"
        size=$(lsblk -d -o SIZE "$disk" -n 2>/dev/null || echo "未知")
        echo "  $((i+1)). $disk (大小: $size)"
    done
    echo ""
    read -p "请选择目标磁盘编号 [1-${#disks[@]}]：" disk_choice
    if [[ ! "$disk_choice" =~ ^[0-9]+$ ]] || [[ $disk_choice -lt 1 ]] || [[ $disk_choice -gt ${#disks[@]} ]]; then
        print_error "无效的选择"
        exit 1
    fi
    TARGET_DISK="${disks[$((disk_choice-1))]}"
    print_info "已选择磁盘: $TARGET_DISK"
}

# 选择 Windows 镜像
select_windows_image() {
    echo ""
    echo "可选 Windows 镜像："
    echo "  1) Windows 2008 R2"
    echo "  2) Windows 2012 R2"
    echo "  3) Windows 2016"
    echo "  4) Windows 2019"
    echo "  5) Windows 2022"
    echo "  6) Windows 10"
    read -p "请选择要安装的系统 [1-6]：" WIN_CHOICE
    if [[ ! "$WIN_CHOICE" =~ ^[1-6]$ ]]; then
        print_error "无效选择"
        exit 1
    fi
    case $WIN_CHOICE in
        1) IMAGE_FILE="Windows-2008R2-Datacenter-cn.qcow2"; IMAGE_NAME="2008 R2" ;;
        2) IMAGE_FILE="Windows-2012R2-Datacenter-cn.qcow2"; IMAGE_NAME="2012 R2" ;;
        3) IMAGE_FILE="Windows-2016-Datacenter-cn.qcow2"; IMAGE_NAME="2016" ;;
        4) IMAGE_FILE="Windows-2019-Datacenter-cn.qcow2"; IMAGE_NAME="2019" ;;
        5) IMAGE_FILE="Windows-2022-Datacenter-cn.qcow2"; IMAGE_NAME="2022" ;;
        6) IMAGE_FILE="Windows10-cn.qcow2"; IMAGE_NAME="10" ;;
    esac
    print_info "已选择: Windows $IMAGE_NAME, 镜像文件: $IMAGE_FILE"
}

# 最终确认
final_confirm() {
    echo ""
    print_header "操作确认"
    print_warning "即将执行以下操作："
    echo "  📌 1. 修复 DNF 源（切换至阿里云镜像）"
    echo "  📌 2. 安装 chntpw + 降级 libgcrypt + 安装 qemu-img"
    echo "  📌 3. 下载 Windows $IMAGE_NAME 镜像（约 3-4 GB）"
    echo "  📌 4. 将镜像写入磁盘 $TARGET_DISK（数据将被完全覆盖！）"
    echo "  📌 5. 自动扩展 NTFS 分区到整个磁盘"
    echo "  📌 6. 挂载 Windows 分区"
    echo "  📌 7. 自动清除 Windows 管理员密码"
    echo ""
    read -p "确认继续？输入 y 继续: " confirm
    if [[ "$confirm" != "y" ]]; then
        print_info "操作已取消"
        exit 0
    fi
}

# ==================== 1. 修复 DNF 源 ====================
fix_dnf_mirror() {
    print_header "1. 修复 DNF 源（切换至阿里云）"

    BACKUP_DIR="/etc/yum.repos.d/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    if ls /etc/yum.repos.d/CentOS-Stream-*.repo 1>/dev/null 2>&1; then
        mv /etc/yum.repos.d/CentOS-Stream-*.repo "$BACKUP_DIR/"
        print_info "已备份原有 repo 到 $BACKUP_DIR"
    fi

    cat > /etc/yum.repos.d/CentOS-Aliyun.repo << 'EOF'
[base]
name=CentOS-Stream-$releasever - Base
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

[appstream]
name=CentOS-Stream-$releasever - AppStream
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/AppStream/x86_64/os/
gpgcheck=0
enabled=1

[extras]
name=CentOS-Stream-$releasever - Extras
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/extras/x86_64/os/
gpgcheck=0
enabled=1
EOF
    print_info "阿里云源配置完成"

    dnf clean all
    print_info "DNF 缓存已清理"

    if dnf repolist &>/dev/null; then
        print_info "DNF 仓库列表获取成功"
    else
        print_error "DNF 仍然无法正常工作，请检查网络"
        exit 1
    fi
}

# ==================== 2. 安装 chntpw 及必要软件 ====================
install_chntpw() {
    print_header "2. 安装 chntpw（降级 libgcrypt）及 qemu-img"

    BACKUP_LIB_DIR="/root/libgcrypt_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_LIB_DIR"
    rpm -qa | grep libgcrypt > "$BACKUP_LIB_DIR/libgcrypt_packages.txt" || true
    print_info "已备份 libgcrypt 包列表到 $BACKUP_LIB_DIR"

    print_step "安装基础依赖 (curl, wget, rpm, qemu-img)..."
    dnf install -y curl wget rpm qemu-img

    print_step "下载兼容版 libgcrypt-1.5.3..."
    LIBCRYPT_RPM="/tmp/libgcrypt-1.5.3-14.el7.x86_64.rpm"
    if [[ ! -f "$LIBCRYPT_RPM" ]]; then
        wget -O "$LIBCRYPT_RPM" \
            "https://yum.oracle.com/repo/OracleLinux/OL7/5/base/x86_64/getPackage/libgcrypt-1.5.3-14.el7.x86_64.rpm" \
            --no-verbose
    fi
    print_info "强制安装 libgcrypt 1.5.3 ..."
    rpm -ivh --force "$LIBCRYPT_RPM"
    print_info "libgcrypt 降级完成"

    print_step "下载 chntpw ..."
    CHNTPW_RPM="/root/chntpw-0.99.6-22.110511.el7.nux.x86_64.rpm"
    if [[ ! -f "$CHNTPW_RPM" ]]; then
        wget -O "$CHNTPW_RPM" \
            "ftp://ftp.icm.edu.pl/vol/pbone/mirrors.coreix.net/li.nux.ro/nux/dextop/el7/x86_64/chntpw-0.99.6-22.110511.el7.nux.x86_64.rpm" \
            --no-verbose
    fi

    if rpm -q chntpw &>/dev/null; then
        print_info "chntpw 已安装，跳过"
    else
        rpm -ivh --nodeps "$CHNTPW_RPM"
        print_info "chntpw 安装完成"
    fi

    if ! command -v chntpw &>/dev/null; then
        print_error "chntpw 命令不可用"
        exit 1
    fi
    print_info "chntpw 命令可用"
}

# ==================== 3. 下载并写入镜像 ====================
download_and_write_image() {
    print_header "3. 下载 Windows 镜像并写入磁盘"

    DOWNLOAD_DIR="/home/kvm/images"
    MIRROR_URL="http://mirror.cloud.idcsmart.com/cloud/images/init-images"
    mkdir -p "$DOWNLOAD_DIR"

    SAVE_PATH="$DOWNLOAD_DIR/$IMAGE_FILE"
    URL="$MIRROR_URL/$IMAGE_FILE"

    if [[ -f "$SAVE_PATH" ]]; then
        print_warning "文件已存在: $SAVE_PATH，将直接使用"
    else
        print_info "开始下载 $IMAGE_FILE ..."
        wget -O "$SAVE_PATH" "$URL"
        if [[ $? -ne 0 ]]; then
            print_error "下载失败"
            exit 1
        fi
    fi
    print_info "下载完成，文件大小: $(ls -lh "$SAVE_PATH" | awk '{print $5}')"

    print_warning "即将写入磁盘 $TARGET_DISK，这将覆盖所有数据！"
    print_step "使用 qemu-img 转换并写入..."
    qemu-img convert -f qcow2 -O raw "$SAVE_PATH" "$TARGET_DISK"
    sync
    print_info "镜像写入完成"

    # 强制刷新分区表，等待设备稳定
    print_step "刷新分区表，等待设备稳定..."
    partprobe "$TARGET_DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 3
}

# ==================== 4. 扩展 NTFS 分区（修复版） ====================
extend_ntfs_partition() {
    print_header "4. 扩展 Windows 分区到整个磁盘"

    # 1. 安装 epel-release（必须，因为 ntfs-3g 在 EPEL 中）
    print_step "安装 epel-release ..."
    if ! rpm -q epel-release &>/dev/null; then
        dnf install -y epel-release --nogpgcheck || {
            print_error "epel-release 安装失败，尝试手动添加 EPEL 源"
            cat > /etc/yum.repos.d/epel.repo << 'EOF'
[epel]
name=Extra Packages for Enterprise Linux 8 - x86_64
baseurl=https://mirrors.aliyun.com/epel/8/Everything/x86_64
gpgcheck=0
enabled=1
EOF
        }
    fi

    # 2. 安装 ntfs-3g 及相关工具
    print_step "安装 ntfs-3g, ntfsprogs, parted ..."
    dnf install -y ntfs-3g ntfsprogs parted --nogpgcheck
    if ! command -v ntfsresize &>/dev/null; then
        print_error "ntfsresize 不可用，请检查网络或手动安装 'ntfs-3g'"
        exit 1
    fi
    if ! command -v ntfsfix &>/dev/null; then
        print_error "ntfsfix 不可用"
        exit 1
    fi
    print_info "必要工具已就绪"

    # 3. 自动识别 NTFS 分区（等待设备稳定）
    print_step "查找 Windows NTFS 分区 ..."
    partprobe "$TARGET_DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 2

    NTFS_PARTS=()
    for i in {1..15}; do
        NTFS_PARTS=()
        while read part; do
            NTFS_PARTS+=("$part")
        done < <(lsblk -o NAME,FSTYPE,TYPE -l -n | grep -i ntfs | grep part | awk '{print "/dev/"$1}')
        if [[ ${#NTFS_PARTS[@]} -gt 0 ]]; then
            print_info "检测到 ${#NTFS_PARTS[@]} 个 NTFS 分区"
            break
        fi
        sleep 1
    done

    if [[ ${#NTFS_PARTS[@]} -eq 0 ]]; then
        print_error "未找到 NTFS 分区，请确认镜像已正确写入"
        exit 1
    fi

    # 4. 选择第一个 NTFS 分区（一般 Windows 在第一个）
    PART="${NTFS_PARTS[0]}"
    DISK=$(echo "$PART" | sed 's/[0-9]*$//')
    PART_NUM=$(echo "$PART" | grep -oE '[0-9]+$')
    print_info "自动选择分区: $PART (磁盘 $DISK, 分区号 $PART_NUM)"

    # 5. 卸载已挂载的分区
    if mountpoint -q "$PART" 2>/dev/null; then
        umount "$PART"
        print_info "已卸载 $PART"
    fi

    # 6. 获取分区起始、磁盘总大小、当前分区大小
    PART_START=$(parted "$DISK" unit B print | grep "^ $PART_NUM" | awk '{print $2}' | sed 's/B//')
    DISK_END=$(parted "$DISK" unit B print | grep "^Disk $DISK" | awk '{print $3}' | sed 's/B//')
    PART_CURR=$(parted "$DISK" unit B print | grep "^ $PART_NUM" | awk '{print $4}' | sed 's/B//')
    FREE=$((DISK_END - PART_START - PART_CURR))
    FREE_GB=$((FREE / 1024 / 1024 / 1024))

    echo "分区起始: ${PART_START} B"
    echo "磁盘总大小: ${DISK_END} B"
    echo "当前分区大小: ${PART_CURR} B"
    echo "空闲空间: ${FREE_GB} GB"

    if [[ $FREE -lt 1048576 ]]; then
        print_warning "空闲空间不足 1MB，无需扩展"
        return 0
    fi

    # 7. 检查 NTFS 文件系统健康状况
    print_step "检查 NTFS 文件系统..."
    ntfsresize -i "$PART" 2>&1 | head -5

    TARGET_END=$((DISK_END - 1048576))
    TARGET_GB=$((TARGET_END / 1024 / 1024 / 1024))
    echo -e "${GREEN}将扩展到约 ${TARGET_GB} GB${NC}"

    # 8. 扩展分区表
    print_step "扩展分区表..."
    parted "$DISK" resizepart "$PART_NUM" "${TARGET_END}B" -s
    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    # 9. 修复 NTFS 引导并扩展文件系统
    print_step "修复引导扇区并扩展文件系统..."
    ntfsfix -b -d "$PART"
    ntfsresize -f "$PART"

    print_info "分区扩展完成"
    echo ""
    echo "最终分区状态:"
    parted "$DISK" unit GB print
}

# ==================== 5. 挂载 Windows 分区 ====================
mount_ntfs() {
    print_header "5. 挂载 Windows 分区"

    # 确保 ntfs-3g 存在
    if ! command -v ntfs-3g &>/dev/null; then
        dnf install -y ntfs-3g
    fi

    # 扫描 NTFS 分区
    print_step "扫描 NTFS 分区..."
    local ntfs_partitions=$(lsblk -f -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT | grep -i ntfs || true)
    if [[ -z "$ntfs_partitions" ]]; then
        print_error "未找到 NTFS 分区"
        echo "当前磁盘分区信息："
        lsblk -f
        exit 1
    fi
    echo ""
    print_info "找到以下 NTFS 分区："
    echo "----------------------------------------"
    echo "$ntfs_partitions"
    echo "----------------------------------------"

    local devices=($(lsblk -o NAME,FSTYPE -l -n | grep -i ntfs | awk '{print "/dev/"$1}'))
    if [[ ${#devices[@]} -eq 0 ]]; then
        print_error "未能获取 NTFS 设备"
        exit 1
    fi
    SELECTED_DEVICE="${devices[0]}"
    print_info "自动选择分区: $SELECTED_DEVICE"

    MOUNT_POINT="/mnt/windows"
    print_info "挂载点: $MOUNT_POINT"

    if [[ -d "$MOUNT_POINT" ]] && mountpoint -q "$MOUNT_POINT"; then
        print_warning "$MOUNT_POINT 已被挂载，将先卸载"
        umount "$MOUNT_POINT"
    fi
    mkdir -p "$MOUNT_POINT"

    print_step "挂载 $SELECTED_DEVICE 到 $MOUNT_POINT ..."
    if mount -t ntfs-3g "$SELECTED_DEVICE" "$MOUNT_POINT"; then
        print_info "挂载成功"
    else
        print_error "挂载失败"
        exit 1
    fi

    if mountpoint -q "$MOUNT_POINT"; then
        print_info "✓ 挂载点验证成功"
        echo ""
        print_info "挂载信息："
        mount | grep "$MOUNT_POINT"
    else
        print_error "挂载验证失败"
        exit 1
    fi
}

# ==================== 6. 自动清除密码 ====================
auto_clear_password() {
    print_header "6. 自动清除 Windows 密码"

    SAM_PATH="/mnt/windows/Windows/System32/config/SAM"
    if [[ ! -f "$SAM_PATH" ]]; then
        print_error "未找到 SAM 文件，密码清除失败"
        exit 1
    fi

    if ! command -v expect &>/dev/null; then
        print_step "安装 expect..."
        dnf install -y expect
    fi

    print_step "运行 chntpw 并自动发送按键（1选择用户，1清除密码，y保存）..."
    expect << EOF
set timeout 10
spawn chntpw "$SAM_PATH"
expect "Select:"
send "1\r"
expect "Write hive files"
send "y\r"
expect eof
EOF

    print_info "密码清除指令已执行。Windows 管理员密码已置空。"
}

# ==================== 7. 重启提示 ====================
reboot_hint() {
    print_header "安装完成提示"
    print_info "Windows 已成功安装并配置完成！"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}✓${NC} 系统镜像：Windows ${IMAGE_NAME}"
    echo -e "${GREEN}✓${NC} 安装磁盘：${TARGET_DISK}"
    echo -e "${GREEN}✓${NC} 管理员密码：${YELLOW}（已清空，无需密码）${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "是否立即重启系统？[y/N]: " reboot_choice
    if [[ "$reboot_choice" == "y" ]] || [[ "$reboot_choice" == "Y" ]]; then
        print_info "系统将在 3 秒后重启..."
        sleep 3
        reboot
    else
        print_info "请记得手动重启系统以进入 Windows"
        print_info "重启命令: reboot"
    fi
}

# ==================== 主函数 ====================
main() {
    # 显示欢迎信息
    clear
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     CentOS 8 Windows 自动部署脚本 v2.0                   ║"
    echo "║     作者：黑虎修改版                                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    
    check_root
    check_centos8
    confirm_magiccube      # ← 新增：智简魔方环境确认
    select_disk
    select_windows_image
    final_confirm          # 具体操作确认

    # 执行主要步骤
    fix_dnf_mirror
    install_chntpw
    download_and_write_image
    extend_ntfs_partition
    mount_ntfs
    auto_clear_password
    reboot_hint            # ← 新增：重启提示

    print_header "🎉 所有操作完成 🎉"
}

# 运行主函数
main
