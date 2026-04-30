# 智j魔f创建的不支持安装windows的云服务器一键安装 Windows 脚本

> 📖 **详细教程**：[博客文章](https://blo.802213.xyz/posts/default/win-in-server)

## 简介

适用于智简魔方面板创建的 CentOS 8 的救援系统里面一键安装 Windows。

> ⚠️ **免责声明**：本脚本仅供学习交流，数据会全部清除，后果自负。

### 要求
- 智简魔方创建的 CentOS 8 / Stream 8
- 救援模式可用
- 服务器不提供 Windows 安装选项（有的话直接用官方的）
- 网络能下载约 4GB 镜像

## 安装方法

### 1. 进入救援模式
通过云服务商控制台切换到救援系统。

### 2. 执行脚本
```bash
bash <(curl -sL https://raw.githubusercontent.com/fanchuanhah/install-windows-in-unsupport-windows-server/refs/heads/main/install.sh)
```

### 3. 按提示操作
- 选择目标磁盘（数据会被覆盖）
- 选择 Windows 版本（2008 R2 / 2012 R2 / 2016 / 2019 / 2022 / 10）
- 确认后等待自动完成（约 10-20 分钟）

### 4. 退出救援模式重启
完成后退出救援模式，点击vnc。

### 5. 安装完了

## 支持版本
| 版本 | 镜像大小 |
|------|---------|
| 2008 R2 / 2012 R2 / 2016 / 2019 / 2022 / 10 | ~3-4 GB |

## 常见问题
- **ntfsresize 不存在**：脚本会自动安装 ntfs-3g
- **重启仍要密码**：手动挂载分区后执行 `chntpw /mnt/.../SAM`
- **磁盘未完全扩展**：进 Windows 后用磁盘管理扩展卷
- **无网络**：使用脚本默认镜像源，已预置驱动

## 链接
- 脚本地址：`https://raw.githubusercontent.com/fanchuanhah/install-windows-in-unsupport-windows-server/refs/heads/main/install.sh`
- 博客教程：`https://blo.802213.xyz/posts/default/win-in-server`
