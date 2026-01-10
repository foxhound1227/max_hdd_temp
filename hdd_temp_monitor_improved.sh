#!/bin/bash

# ================= 配置区域 =================
# 允许通过环境变量覆盖配置
DRIVES=(${DRIVES:-"/dev/sda" "/dev/sdb"})
OUTPUT_DIR="${OUTPUT_DIR:-/vol1/1000/docker/CoolerControl}"
OUTPUT_FILE="${OUTPUT_FILE:-max_hdd_temp.txt}"
LOG_FILE="${LOG_FILE:-hdd_monitor.log}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5m}"
DEFAULT_TEMP="${DEFAULT_TEMP:-15}"
# 日志最大体积 (例如 5MB)
MAX_LOG_SIZE=$((5 * 1024 * 1024))
# ===========================================

# 检查必要的命令是否存在
for cmd in smartctl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Command '$cmd' not found."
        exit 1
    fi
done

# 确保输出目录存在
mkdir -p "$OUTPUT_DIR"
LOG_PATH="$OUTPUT_DIR/$LOG_FILE"

# 日志函数 (带简单轮转)
log() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_entry="[$timestamp] $msg"
    
    echo "$log_entry"
    
    # 检查日志大小，如果超过限制则备份并清空
    if [ -f "$LOG_PATH" ] && [ $(stat -c%s "$LOG_PATH") -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_PATH" "$LOG_PATH.old"
        echo "[$timestamp] Log rotated" >> "$LOG_PATH"
    fi
    echo "$log_entry" >> "$LOG_PATH"
}

# 自动检测 CPU 温度源
detect_cpu_source() {
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -f "$zone/type" ] || continue
        type=$(cat "$zone/type")
        case "$type" in
            x86_pkg_temp|k10temp|coretemp|cpu-thermal|cpu_thermal)
                echo "$zone/temp"
                return
                ;;
        esac
    done
    echo "/sys/class/thermal/thermal_zone0/temp"
}

CPU_TEMP_SOURCE=$(detect_cpu_source)
log "CPU 温度源: $CPU_TEMP_SOURCE"

get_cpu_temp() {
    if [ -f "$CPU_TEMP_SOURCE" ]; then
        echo $(( $(cat "$CPU_TEMP_SOURCE") / 1000 ))
    else
        echo 0
    fi
}

log "监控启动. 列表: ${DRIVES[*]}, 间隔: $CHECK_INTERVAL"

LAST_WRITTEN_TEMP=-1
# 计数器
CPU_OVER_65_COUNT=0
CPU_OVER_60_COUNT=0
CPU_BELOW_60_COUNT=0
CURRENT_SIMULATED_TEMP=0

while true; do
    MAX_TEMP=0
    TEMP_FOUND=false
    
    # 1. 检查硬盘温度
    for drive in "${DRIVES[@]}"; do
        if [ ! -e "$drive" ]; then
            log "警告: Hdd $drive not found" # 简化日志
            continue
        fi

        # 使用 smartctl -n standby 避免唤醒休眠硬盘
        # 优先匹配 194 (Temperature_Celsius), 其次 190 (Airflow_Temperature)
        # 190 有时表示 100-temp，但现代硬盘通常是 raw value. 此处假设 raw value.
        temp=$(smartctl -A -n standby "$drive" | awk '$1=="194" || $1=="190" {print $10; exit}')
        
        if [ -n "$temp" ] && [ "$temp" -gt 0 ]; then
             if [ "$temp" -gt "$MAX_TEMP" ]; then
                MAX_TEMP=$temp
             fi
             TEMP_FOUND=true
        fi
    done

    # 2. 检查 CPU 温度并计算模拟温度
    CURRENT_CPU_TEMP=$(get_cpu_temp)
    
    # 状态机逻辑
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

    # 切换模拟温度
    if [ "$CPU_OVER_65_COUNT" -ge 2 ]; then
        CURRENT_SIMULATED_TEMP=45
    elif [ "$CPU_OVER_60_COUNT" -ge 2 ]; then
        CURRENT_SIMULATED_TEMP=40
    elif [ "$CPU_BELOW_60_COUNT" -ge 2 ]; then
        CURRENT_SIMULATED_TEMP=10
    fi

    # 3. 决策最终温度
    FINAL_TEMP=$DEFAULT_TEMP
    
    # 如果硬盘在线，基准最高温是硬盘最高温
    if [ "$TEMP_FOUND" = true ]; then
        FINAL_TEMP=$MAX_TEMP
    fi

    # 混合控制策略: 取 MAX(硬盘温度, 模拟CPU负载温度)
    if [ "$CURRENT_SIMULATED_TEMP" -gt "$FINAL_TEMP" ]; then
        FINAL_TEMP=$CURRENT_SIMULATED_TEMP
        LOG_REASON="Activated Simulated Temp (CPU: $CURRENT_CPU_TEMP)"
    else
        LOG_REASON="Real HDD Max"
    fi

    # [DEBUG] 打印详细状态以排查逻辑问题
    log "[DEBUG] CPU:$CURRENT_CPU_TEMP|Counters(>65:$CPU_OVER_65_COUNT >60:$CPU_OVER_60_COUNT <60:$CPU_BELOW_60_COUNT)|Sim:$CURRENT_SIMULATED_TEMP|HDD:$MAX_TEMP|Final:$FINAL_TEMP"

    # 转换为毫摄氏度
    FINAL_TEMP_MILLI=$((FINAL_TEMP * 1000))
    
    target_file="$OUTPUT_DIR/$OUTPUT_FILE"
    if [ "$FINAL_TEMP_MILLI" -ne "$LAST_WRITTEN_TEMP" ]; then
        log "Update: $FINAL_TEMP°C ($LOG_REASON) -> Write"
        echo "$FINAL_TEMP_MILLI" > "$target_file"
        LAST_WRITTEN_TEMP=$FINAL_TEMP_MILLI
    else
        # 可选: 减少日志刷屏，仅在变化时记录，或每N次记录心跳
        : 
    fi

    sleep "$CHECK_INTERVAL"
done
