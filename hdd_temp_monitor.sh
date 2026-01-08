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

# 自动检测 CPU 温度源
detect_cpu_source() {
    # 优先查找常见的 CPU 传感器类型
    for zone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$zone/type" ]; then
            type=$(cat "$zone/type")
            # 常见的 CPU 温度传感器类型:
            # x86_pkg_temp (Intel), k10temp (AMD), coretemp, cpu-thermal (ARM/Generic)
            if [[ "$type" == "x86_pkg_temp" ]] || \
               [[ "$type" == "k10temp" ]] || \
               [[ "$type" == "coretemp" ]] || \
               [[ "$type" == "cpu-thermal" ]] || \
               [[ "$type" == "cpu_thermal" ]]; then
                echo "$zone/temp"
                return
            fi
        fi
    done
    # 如果没找到特定的，默认回退到 thermal_zone0
    echo "/sys/class/thermal/thermal_zone0/temp"
}

# CPU 温度源 (自动检测)
CPU_TEMP_SOURCE=$(detect_cpu_source)

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

# 获取 CPU 温度 (返回摄氏度)
get_cpu_temp() {
    if [ -f "$CPU_TEMP_SOURCE" ]; then
        local temp_m=$(cat "$CPU_TEMP_SOURCE")
        # 转换为摄氏度 (sysfs 通常返回毫摄氏度)
        echo $((temp_m / 1000))
    else
        echo 0
    fi
}

# 获取 CPU 温度源的类型名称 (用于日志显示)
get_cpu_source_type() {
    local source_dir=$(dirname "$CPU_TEMP_SOURCE")
    if [ -f "$source_dir/type" ]; then
        cat "$source_dir/type"
    else
        echo "unknown"
    fi
}

log "硬盘温度监控服务已启动"
log "监控列表: ${DRIVES[*]}"
log "CPU 温度源: $CPU_TEMP_SOURCE (类型: $(get_cpu_source_type))"
log "检查间隔: $CHECK_INTERVAL"
log "日志文件: $OUTPUT_DIR/$LOG_FILE"
log "默认温度: $DEFAULT_TEMP °C (当全部休眠或未找到硬盘时使用)"

# 上次写入的温度 (初始化为 -1，确保第一次一定会写入)
LAST_WRITTEN_TEMP=-1

# CPU 温度超标计数器
CPU_OVER_60_COUNT=0
CPU_OVER_65_COUNT=0
CPU_BELOW_60_COUNT=0

# 当前生效的模拟温度 (初始化为 0)
CURRENT_SIMULATED_TEMP=0

while true; do
    MAX_TEMP=0
    TEMP_FOUND=false
    
    log "开始检查硬盘温度..."

    # 1. 检查硬盘温度
    for drive in "${DRIVES[@]}"; do
        # 检查硬盘是否存在
        if [ ! -e "$drive" ]; then
            log "警告: 找不到硬盘 $drive"
            continue
        fi

        # 检查硬盘是否休眠
        # hdparm -C 返回 "drive state is:  active/idle" 或 "standby"
        state_output=$(hdparm -C "$drive" 2>&1)
        
        if echo "$state_output" | grep -q "standby"; then
            log "硬盘 $drive 正在休眠 (standby)，跳过..."
            continue
        elif echo "$state_output" | grep -q "sleeping"; then
            log "硬盘 $drive 正在休眠 (sleeping)，跳过..."
            continue
        fi

        # 读取温度
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

    # 2. 检查 CPU 温度
    CURRENT_CPU_TEMP=$(get_cpu_temp)
    # SIMULATED_HDD_TEMP 将使用 CURRENT_SIMULATED_TEMP，除非发生状态切换

    # 更新计数器 (区间互斥，确保状态切换需要连续确认)
    if [ "$CURRENT_CPU_TEMP" -gt 65 ]; then
        CPU_OVER_65_COUNT=$((CPU_OVER_65_COUNT + 1))
        CPU_OVER_60_COUNT=0
        CPU_BELOW_60_COUNT=0
    elif [ "$CURRENT_CPU_TEMP" -gt 60 ]; then
        CPU_OVER_65_COUNT=0
        CPU_OVER_60_COUNT=$((CPU_OVER_60_COUNT + 1))
        CPU_BELOW_60_COUNT=0
    else
        CPU_OVER_65_COUNT=0
        CPU_OVER_60_COUNT=0
        CPU_BELOW_60_COUNT=$((CPU_BELOW_60_COUNT + 1))
    fi

    # 判断是否需要切换模拟温度
    if [ "$CPU_OVER_65_COUNT" -ge 2 ]; then
        log "CPU 温度连续 $CPU_OVER_65_COUNT 次超过 65°C (当前: $CURRENT_CPU_TEMP°C) -> 切换模拟温度为 45°C"
        CURRENT_SIMULATED_TEMP=45
    elif [ "$CPU_OVER_60_COUNT" -ge 2 ]; then
        log "CPU 温度连续 $CPU_OVER_60_COUNT 次超过 60°C (当前: $CURRENT_CPU_TEMP°C) -> 切换模拟温度为 40°C"
        CURRENT_SIMULATED_TEMP=40
    elif [ "$CPU_BELOW_60_COUNT" -ge 2 ]; then
        log "CPU 温度连续 $CPU_BELOW_60_COUNT 次低于 60°C (当前: $CURRENT_CPU_TEMP°C) -> 切换模拟温度为 10°C"
        CURRENT_SIMULATED_TEMP=10
    else
        # 状态保持 (计数器未达标)
        log "CPU 温度 $CURRENT_CPU_TEMP°C (状态未确认: >65:$CPU_OVER_65_COUNT, >60:$CPU_OVER_60_COUNT, <60:$CPU_BELOW_60_COUNT) -> 保持当前模拟温度 $CURRENT_SIMULATED_TEMP°C"
    fi

    SIMULATED_HDD_TEMP=$CURRENT_SIMULATED_TEMP

    # 3. 汇总最高温度
    # 如果有模拟温度且高于当前硬盘最高温度，则使用模拟温度
    if [ "$SIMULATED_HDD_TEMP" -gt "$MAX_TEMP" ]; then
        MAX_TEMP=$SIMULATED_HDD_TEMP
        # 如果使用了模拟温度，视为找到了有效温度 (即使硬盘都在休眠)
        TEMP_FOUND=true
        log "使用模拟硬盘温度 $SIMULATED_HDD_TEMP °C 作为最高温度"
    fi

    # 4. 确定要写入的温度值 (毫摄氏度)
    TARGET_TEMP_MILLI=0
    
    if [ "$TEMP_FOUND" = true ]; then
        # 转换为毫摄氏度
        TARGET_TEMP_MILLI=$((MAX_TEMP * 1000))
        LOG_MSG="检测到最高温度: $MAX_TEMP °C ($TARGET_TEMP_MILLI)"
    else
        # 转换为毫摄氏度
        TARGET_TEMP_MILLI=$((DEFAULT_TEMP * 1000))
        LOG_MSG="未读取到任何有效温度，使用默认值 $DEFAULT_TEMP °C ($TARGET_TEMP_MILLI)"
    fi

    # 5. 检查温度是否变化并写入
    target_file="$OUTPUT_DIR/$OUTPUT_FILE"
    
    if [ "$TARGET_TEMP_MILLI" -ne "$LAST_WRITTEN_TEMP" ]; then
        log "$LOG_MSG -> 温度发生变化，执行写入"
        echo "$TARGET_TEMP_MILLI" > "$target_file"
        LAST_WRITTEN_TEMP=$TARGET_TEMP_MILLI
    else
        log "$LOG_MSG -> 温度未变化，跳过写入"
    fi

    # 等待下一次检查
    sleep "$CHECK_INTERVAL"
done
