# Max HDD Temp Monitor

一个用于监控硬盘温度的 Bash 脚本，具备智能 CPU 温度模拟功能，用于辅助风扇控制策略。

## 简介

此脚本旨在解决某些环境下（如使用 CoolerControl 等工具时）硬盘温度无法直接触发合理的风扇曲线的问题。它不仅监控物理硬盘的最高温度，还会根据 CPU 的温度状态“模拟”出一个较高的硬盘温度值，从而强制风扇控制器在 CPU 高负载时提高转速，即使硬盘本身并不热。

## 功能特性

*   **多硬盘监控**：自动轮询配置列表中的所有硬盘，获取最高温度。
*   **智能模拟机制**：
    *   当 CPU 温度 > 65°C 时，模拟输出 45°C。
    *   当 CPU 温度 > 60°C 时，模拟输出 40°C。
    *   当 CPU 温度 < 60°C 时，模拟输出 10°C (低负载静音模式)。
*   **混合控制策略**：最终输出取 **物理硬盘最高温** 和 **模拟温度** 中的最大值。
*   **自动日志轮转**：内置日志记录与自动清理功能，防止日志文件无限增长。
*   **低功耗设计**：使用 `smartctl -n standby`，避免唤醒处于休眠状态的机械硬盘。

## 依赖要求

*   Linux 操作系统 (Bash 环境)
*   `smartctl` (smartmontools)
*   root 权限 (读取 SMART 信息需要)

## 安装与配置

1.  **克隆仓库**
    ```bash
    git clone https://github.com/foxhound1227/max_hdd_temp.git
    cd max_hdd_temp
    ```

2.  **修改配置 (可选)**
    脚本支持通过环境变量覆盖默认配置，或者直接修改 `hdd_temp_monitor.sh` 顶部的配置区域：
    ```bash
    DRIVES=("/dev/sda" "/dev/sdb" "/dev/sdc") # 要监控的磁盘列表
    OUTPUT_FILE="max_hdd_temp.txt"            # 温度输出文件
    CHECK_INTERVAL="5m"                       # 检查间隔
    ```

3.  **配置 Systemd 服务**
    编辑 `hdd_monitor.service` 文件，修改 `ExecStart` 路径为你实际的脚本存放路径：
    ```ini
    [Service]
    ExecStart=/bin/bash /path/to/your/hdd_temp_monitor.sh
    ```

4.  **安装并启动服务**
    ```bash
    # 复制服务文件 (假设在当前目录)
    sudo cp hdd_monitor.service /etc/systemd/system/

    # 重载配置
    sudo systemctl daemon-reload

    # 启动服务
    sudo systemctl enable --now hdd_monitor.service

    # 查看状态
    sudo systemctl status hdd_monitor.service
    ```

## 输出

脚本将在指定的 `OUTPUT_DIR` (默认为 `/vol1/1000/docker/CoolerControl`) 生成一个包含最高温度（毫摄氏度）的文件。CoolerControl 或其他工具可以读取此文件作为自定义传感器源。

## 许可证

MIT License
