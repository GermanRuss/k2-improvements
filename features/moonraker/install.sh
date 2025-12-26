#!/bin/ash

set -e

SCRIPT_DIR=$(readlink -f $(dirname ${0}))

cd ${HOME}

export TMPDIR=/mnt/UDISK/tmp
mkdir -p "${TMPDIR}"

# MUST have Entware installed
if [ ! -f /opt/bin/opkg ]; then
    echo "E: you must have entware installed!"
    exit 1
fi

# handle entware being installed in the current login
if [ -f /etc/profile.d/entware.sh ]; then
    echo ${PATH} | grep -q /opt || source /etc/profile.d/entware.sh
fi

if ! type -p git > /dev/null; then
    opkg install git
fi

progress() {
    echo "#### ${1}"
}

install_virtualenv() {
    progress "Installing virtualenv ..."
    type -p virtualenv > /dev/null || pip install virtualenv

    # update pip to pull pre-built wheels
    if ! grep -qE '^extra-index-url=https://www.piwheels.org/simple$' /etc/pip.conf; then
        echo 'extra-index-url=https://www.piwheels.org/simple' >> /etc/pip.conf
    fi
}

remove_legacy_symlinks() {
    progress "Removing legacy symlinks ..."
    for ENTRY in moonraker moonraker-env; do
        if [ -L ${ENTRY} ]; then
            rm -f ${ENTRY}
        fi
    done
}

fetch_moonraker() {
    progress "Fetching mooonraker ..."
    # clone my mooonraker fork
    if [ -d moonraker/.git ]; then
        git -C moonraker pull
    else
        git clone https://github.com/jamincollins/moonraker.git
    fi
    # ensure we are on the k2 branch
    git -C moonraker checkout k2
}

create_moonraker_venv() {
    progress "Creating mooonraker venv..."
    # python 3.9.12
    test -d moonraker-env || virtualenv -p /usr/bin/python3 ~/moonraker-env

    # Установка зависимостей для K2 Plus
    echo "Installing dependencies for K2 Plus..."
    
    # Создаем временный requirements файл без проблемных зависимостей
    TEMP_REQ="/tmp/moonraker-requirements.txt"
    if [ -f "moonraker/scripts/moonraker-requirements.txt" ]; then
        # Копируем оригинальные требования
        cp moonraker/scripts/moonraker-requirements.txt ${TEMP_REQ}
    fi
    
    # Установка основных зависимостей
    ./moonraker-env/bin/pip \
        install \
        --upgrade \
        --find-links=${SCRIPT_DIR}/wheels \
        --requirement ${TEMP_REQ} \
        --no-build-isolation
    
    # Установка lmdb (уже работает, как видно из лога)
    ./moonraker-env/bin/pip install lmdb --no-build-isolation
    
    # Исправляем fix_venv.py для Python 3.9
    fix_fix_venv_script
}

fix_fix_venv_script() {
    progress "Fixing fix_venv.py for Python 3.9..."
    
    # Получаем версию Python
    PY_VERSION=$(./moonraker-env/bin/python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_SUFFIX=$(./moonraker-env/bin/python -c "import sys; print(f'cpython-{sys.version_info.major}{sys.version_info.minor}')")
    
    echo "Python version: ${PY_VERSION}, suffix: ${PY_SUFFIX}"
    
    # Исправляем скрипт fix_venv.py
    FIX_VENV_SCRIPT="${SCRIPT_DIR}/../../scripts/fix_venv.py"
    if [ -f "${FIX_VENV_SCRIPT}" ]; then
        echo "Patching fix_venv.py for Python ${PY_VERSION}..."
        # Заменяем ожидаемый суффикс в скрипте
        sed -i "s/\.cpython-311-arm-linux-gnueabi\.so/\.cpython-${PY_VERSION//./}-arm-linux-gnueabi\.so/g" "${FIX_VENV_SCRIPT}"
        sed -i "s/Expected suffix: \.cpython-311-arm-linux-gnueabi\.so/Expected suffix: \.cpython-${PY_VERSION//./}-arm-linux-gnueabi\.so/g" "${FIX_VENV_SCRIPT}"
    fi
    
    # Запускаем исправленный скрипт
    if [ -f "${FIX_VENV_SCRIPT}" ]; then
        python3 "${FIX_VENV_SCRIPT}" ~/moonraker-env
    else
        echo "Warning: fix_venv.py not found, skipping..."
    fi
}

install_libs() {
    progress "Installing mooonraker libs ..."
    for LIB in ${SCRIPT_DIR}/libs/*.so*; do
        if [ -f "${LIB}" ]; then
            ln -sf ${LIB} /lib/
            echo "Linked: ${LIB} -> /lib/"
        fi
    done
}

replace_moonraker() {
    progress "Stopping legacy mooonraker ..."
    /etc/init.d/moonraker stop 2>/dev/null || true
    
    # Даем время для остановки
    sleep 2

    progress "Replacing legacy mooonraker with mainline ..."

    # Создаем директории если их нет
    mkdir -p /mnt/UDISK/printer_data/config
    mkdir -p /opt/etc/init.d

    # update init script location for new config file location
    rm -f /etc/rc.d/S*moonraker 2>/dev/null || true
    
    if [ -f "${SCRIPT_DIR}/moonraker.init" ]; then
        ln -sf ${SCRIPT_DIR}/moonraker.init /etc/init.d/moonraker
        ln -sf ${SCRIPT_DIR}/moonraker.init /opt/etc/init.d/S56moonraker
        chmod +x /etc/init.d/moonraker
    else
        echo "Warning: moonraker.init not found at ${SCRIPT_DIR}/moonraker.init"
        # Создаем простой init скрипт
        create_moonraker_init_script
    fi

    # full copy not symlink here
    if [ -f "${SCRIPT_DIR}/moonraker.conf" ]; then
        cp ${SCRIPT_DIR}/moonraker.conf /mnt/UDISK/printer_data/config/moonraker.conf
    else
        echo "Warning: moonraker.conf not found, creating default..."
        create_default_moonraker_conf
    fi

    progress "Starting mooonraker ..."
    /etc/init.d/moonraker start
    
    # Даем время для запуска
    sleep 3
}

create_moonraker_init_script() {
    cat > /etc/init.d/moonraker << 'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /mnt/UDISK/root/moonraker-env/bin/python /mnt/UDISK/root/moonraker/moonraker/moonraker.py -c /mnt/UDISK/printer_data/config/moonraker.conf -l /tmp/moonraker.log
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    killall -9 python 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/moonraker
    ln -sf /etc/init.d/moonraker /opt/etc/init.d/S56moonraker
}

create_default_moonraker_conf() {
    cat > /mnt/UDISK/printer_data/config/moonraker.conf << 'EOF'
[server]
host: 0.0.0.0
port: 7125
klippy_uds_address: /tmp/klippy_uds

[authorization]
enabled: false
trusted_clients:
  10.0.0.0/8
  127.0.0.0/8
  169.254.0.0/16
  172.16.0.0/12
  192.168.0.0/16
  FE80::/10
  ::1/128

[file_manager]
config_path: /mnt/UDISK/printer_data/config
log_path: /tmp/klipper_logs

[octoprint_compat]

[history]

[update_manager]
enable_auto_refresh: true
EOF
}

modify_moonraker_asvc() {
    progress "Modifying moonraker.asvc ..."
    MOONRAKER_ASVC=/mnt/UDISK/printer_data/moonraker.asvc
    
    # Создаем файл если его нет
    if [ ! -f "${MOONRAKER_ASVC}" ]; then
        echo "Creating moonraker.asvc file..."
        mkdir -p /mnt/UDISK/printer_data
        touch "${MOONRAKER_ASVC}"
    fi
    
    # Добавляем сервисы если их нет
    for SERVICE in webrtc cartographer klipper; do
        if ! grep -qE "^${SERVICE}$" "${MOONRAKER_ASVC}" 2>/dev/null; then
            echo "${SERVICE}" >> "${MOONRAKER_ASVC}"
            echo "Added service: ${SERVICE}"
        fi
    done
}

wait_for_moonraker() {
    progress "Waiting for moonraker to start ..."
    
    # Проверяем, запущен ли процесс
    if pgrep -f "moonraker.*py" > /dev/null; then
        echo "Moonraker process is running"
    else
        echo "Warning: Moonraker process not found, checking logs..."
        if [ -f "/tmp/moonraker.log" ]; then
            tail -20 /tmp/moonraker.log
        fi
    fi
    
    # Пробуем подключиться к порту
    count=0
    while ! nc -z 127.0.0.1 7125 2>/dev/null; do
        if [ $count -gt 30 ]; then
            echo "Warning: moonraker is not responding on port 7125"
            echo "Check /tmp/moonraker.log for errors"
            echo "Trying to start moonraker manually..."
            
            # Пробуем запустить вручную
            cd ~/moonraker
            nohup ~/moonraker-env/bin/python moonraker/moonraker.py \
                -c /mnt/UDISK/printer_data/config/moonraker.conf \
                -l /tmp/moonraker.log &
            
            sleep 5
            break
        fi
        count=$((count + 1))
        sleep 1
    done
    
    if nc -z 127.0.0.1 7125 2>/dev/null; then
        echo "Success: Moonraker is running on port 7125"
    else
        echo "Error: Moonraker failed to start properly"
        echo "Please check:"
        echo "1. /tmp/moonraker.log"
        echo "2. ps aux | grep moonraker"
        echo "3. netstat -tlnp"
    fi
}

# Установка системных зависимостей
install_system_deps() {
    progress "Installing system dependencies..."
    
    # Устанавливаем netcat для проверки портов
    if ! command -v nc >/dev/null 2>&1; then
        opkg install netcat 2>/dev/null || \
        opkg install netcat-openbsd 2>/dev/null || \
        echo "Warning: netcat not installed"
    fi
}

# Главная установка
install_system_deps
install_virtualenv
remove_legacy_symlinks
fetch_moonraker
create_moonraker_venv
install_libs
modify_moonraker_asvc
replace_moonraker
wait_for_moonraker

echo "========================================"
echo "Moonraker installation attempt completed"
echo "Check status with: /etc/init.d/moonraker status"
echo "Check logs: tail -f /tmp/moonraker.log"
echo "========================================"
