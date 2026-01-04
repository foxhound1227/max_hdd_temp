#!/bin/bash

# ================= 配置区域 =================
# 需要读取温度的硬盘列表，用空格分隔
# 例如: DRIVES=("/dev/sda" "/dev/sdb" "/dev/sdc")
DRIVES=("/dev/sda" "/dev/sdb")

# 输出目录
OUTPUT_DIR="/vol1/1000/docker/CoolerControl"
# 输出文件名
OUTPUT_FILE="max_hdd_temp.txt"
# 日志文件名
LOG_FILE="hdd_monitor.log"

# 默认温度 (当找不到硬盘或全部休眠时写入)
# 单位: 摄氏度 (脚本写入时会自动转换为毫摄氏度, 即 * 1000)
DEFAULT_TEMP=15

# 检查间隔时间 (支持 s=秒, m=分, h=时)
# 例如: "10m" 表示 10 分钟, "60s" 表示 60 秒
CHECK_INTERVAL="10m"
# ===========================================

# 确保输出目录存在
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
fi

# 定义日志函数
log() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    # 同时输出到屏幕和日志文件
    echo "[$timestamp] $msg" | tee -a "$OUTPUT_DIR/$LOG_FILE"
}

log "硬盘温度监控服务已启动"
log "监控列表: ${DRIVES[*]}"
log "检查间隔: $CHECK_INTERVAL"
log "日志文件: $OUTPUT_DIR/$LOG_FILE"
log "默认温度: $DEFAULT_TEMP °C (当全部休眠或未找到硬盘时使用)"

while true; do
    MAX_TEMP=0
    TEMP_FOUND=false
    
    log "开始检查硬盘温度..."

    for drive in "${DRIVES[@]}"; do
        # 检查硬盘是否存在
        if [ ! -e "$drive" ]; then
            log "警告: 找不到硬盘 $drive"
            continue
        fi

        # 1. 检查硬盘是否休眠
        # hdparm -C 返回 "drive state is:  active/idle" 或 "standby"
        # 注意: 需要 root 权限运行
        state_output=$(hdparm -C "$drive" 2>&1)
        
        if echo "$state_output" | grep -q "standby"; then
            log "硬盘 $drive 正在休眠 (standby)，跳过..."
            continue
        elif echo "$state_output" | grep -q "sleeping"; then
            log "硬盘 $drive 正在休眠 (sleeping)，跳过..."
            continue
        fi

        # 2. 读取温度
        # 使用 smartctl 读取 Attribute 194 (Temperature_Celsius) 或 190 (Airflow_Temperature_Cel)
        # -A: 仅显示属性
        # -n standby: 如果硬盘在休眠则不唤醒 (作为双重保险，虽然上面已经检查过了)
        temp=$(smartctl -A -n standby "$drive" | grep -E "^194|^190" | awk '{print $10}' | head -n 1)

        if [ -n "$temp" ] && [ "$temp" -gt 0 ]; then
            log "硬盘 $drive 温度: $temp °C"
            TEMP_FOUND=true
            if [ "$temp" -gt "$MAX_TEMP" ]; then
                MAX_TEMP=$temp
            fi
        else
            log "无法读取硬盘 $drive 的温度"
        fi
    done

    # 写入最高温度 (转换为毫摄氏度: x1000)
    target_file="$OUTPUT_DIR/$OUTPUT_FILE"
    if [ "$TEMP_FOUND" = true ]; then
        # 转换为毫摄氏度
        MAX_TEMP_MILLI=$((MAX_TEMP * 1000))
        log "写入最高温度: $MAX_TEMP °C ($MAX_TEMP_MILLI) 到 $target_file"
        echo "$MAX_TEMP_MILLI" > "$target_file"
    else
        # 转换为毫摄氏度
        DEFAULT_TEMP_MILLI=$((DEFAULT_TEMP * 1000))
        log "未读取到任何有效温度 (可能所有硬盘都在休眠或不存在)，写入默认值 $DEFAULT_TEMP °C ($DEFAULT_TEMP_MILLI)"
        # 写入默认温度以便风扇控制软件知道无需降温
        echo "$DEFAULT_TEMP_MILLI" > "$target_file"
    fi

    # 等待下一次检查
    sleep "$CHECK_INTERVAL"
done
