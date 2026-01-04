# HDD 温度监控与输出

- 作用
  - 监控指定硬盘的温度，自动跳过处于休眠的硬盘
  - 将多个硬盘中的最高温度写入到指定目录文件，单位为毫摄氏度（符合 sysfs 数据格式）
  - 支持循环运行与可配置的检查间隔，支持系统服务方式运行

- 文件位置
  - 脚本: [hdd_temp_monitor.sh]
  - 服务: [hdd_temp_monitor.service]
  - 输出目录: `/vol1/1000/docker/CoolerControl`
  - 输出文件: `/vol1/1000/docker/CoolerControl/max_hdd_temp.txt`（单行整数，毫摄氏度）
  - 日志文件: `/vol1/1000/docker/CoolerControl/hdd_monitor.log`

## 前置条件
- 以 root 权限运行（hdparm / smartctl 需要）
- 安装依赖：
  ```bash
  apt install hdparm smartmontools
  ```
- 确保输出目录可写，脚本会自动创建

## 配置
- 编辑脚本顶部参数：
  - 监控硬盘列表：
    ```bash
    DRIVES=("/dev/sda" "/dev/sdb")
    ```
  - 检查间隔（支持 s=秒, m=分, h=小时）：
    ```bash
    CHECK_INTERVAL="10m"
    ```
  - 默认温度（摄氏度，写入时自动换算为毫摄氏度）：
    ```bash
    DEFAULT_TEMP=15
    ```
- 输出格式说明
  - 写入文件内容为毫摄氏度的定点整数（sysfs 标准）
  - 示例：32°C -> `32000`；默认 15°C -> `15000`

## 手动运行验证
```bash
chmod +x hdd_temp_monitor.sh
sudo ./hdd_temp_monitor.sh
```
- 验证输出文件：
  ```bash
  cat /vol1/1000/docker/CoolerControl/max_hdd_temp.txt
  # 应看到形如 32000 的整数
  ```
- 查看运行日志：
  ```bash
  tail -f /vol1/1000/docker/CoolerControl/hdd_monitor.log
  ```

## 作为系统服务加载（systemd）
- 将脚本部署到标准路径并赋权：
  ```bash
  sudo cp hdd_temp_monitor.sh /usr/local/bin/hdd_temp_monitor.sh
  sudo chmod +x /usr/local/bin/hdd_temp_monitor.sh
  ```
- 确认服务文件中的 ExecStart 路径正确：
  - 打开文件: [hdd_temp_monitor.service]
  - 关键配置：
    ```ini
    ExecStart=/usr/local/bin/hdd_temp_monitor.sh
    User=root
    ```
- 安装服务文件到 systemd：
  ```bash
  sudo cp hdd_temp_monitor.service /etc/systemd/system/hdd_temp_monitor.service
  ```
- 加载并启用服务：
  ```bash
  sudo systemctl daemon-reload
  sudo systemctl enable hdd_temp_monitor.service
  sudo systemctl start hdd_temp_monitor.service
  ```
- 查看服务状态与日志：
  ```bash
  systemctl status hdd_temp_monitor.service
  journalctl -u hdd_temp_monitor.service -f
  # 或查看脚本日志
  tail -f /vol1/1000/docker/CoolerControl/hdd_monitor.log
  ```
- 更新与重载：
  ```bash
  # 修改了脚本：
  sudo systemctl restart hdd_temp_monitor.service

  # 修改了 service 文件：
  sudo systemctl daemon-reload
  sudo systemctl restart hdd_temp_monitor.service
  ```
- 停止与禁用：
  ```bash
  sudo systemctl stop hdd_temp_monitor.service
  sudo systemctl disable hdd_temp_monitor.service
  ```

## 说明与行为
- 休眠保护：读取前使用 `hdparm -C` 检查；休眠盘跳过，不唤醒
- 多盘策略：取所有活跃硬盘温度中的最高值
- 回退逻辑：全部休眠或找不到硬盘时，写入默认温度（毫摄氏度）
- 日志包含每次检查的状态与写入值，便于排查

