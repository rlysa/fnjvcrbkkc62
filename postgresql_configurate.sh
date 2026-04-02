#!/bin/bash

# Проверка root
[[ $EUID -ne 0 ]] && echo "Запустите от root" && exit 1

ask_confirmation() {
    read -p "$1 (y/n): " resp
    [[ "$resp" =~ ^[yY] ]]
}

# 1. Данные и пароли
HOST=$(hostname)
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "Host: $HOST | IP: $IP_ADDR"
ask_confirmation "Данные верны?" || exit 1

generate_secure_password() {
    local len=16; local inner_len=$((len - 2))
    local UPPER='ABCDEFGHJKLMNPQRSTUVWXYZ'; local LOWER='abcdefghijkmnopqrstuvwxyz'
    local DIGITS='0123456789'; local SPECIAL='!@#$%^&*()-_=+[]{};:<>?'
    local ALL="$UPPER$LOWER$DIGITS$SPECIAL"; local LETTERS="$UPPER$LOWER"
    local inner="$(tr -dc "$UPPER" < /dev/urandom | head -c1; tr -dc "$LOWER" < /dev/urandom | head -c1; tr -dc "$DIGITS" < /dev/urandom | head -c1; tr -dc "$SPECIAL" < /dev/urandom | head -c1; tr -dc "$ALL" < /dev/urandom | head -c$((inner_len - 4)))"
    echo "$(tr -dc "$LETTERS" < /dev/urandom | head -c1)$(echo "$inner" | fold -w1 | shuf | tr -d '\n')$(tr -dc "$LETTERS" < /dev/urandom | head -c1)"
}

PASSDB=$(generate_secure_password); PASSDBIAM=$(generate_secure_password)
PASS_FILE="./${HOST}_ksc_pass.txt"
cat > "$PASS_FILE" <<EOF
Host: $HOST
kscdbadmin: $PASSDB
iamdbadmin: $PASSDBIAM
EOF
chmod 600 "$PASS_FILE"

# 2. Поиск конфига
echo "=== Поиск конфигурации PostgreSQL ==="
PG_CONF=""
for path in /var/lib/pgsql/*/data/postgresql.conf \
            /var/lib/pgsql/data/postgresql.conf \
            /etc/postgresql/*/main/postgresql.conf \
            /var/lib/postgres/data/postgresql.conf; do
    [ -f "$path" ] && PG_CONF="$path" && break
done

if [ -z "$PG_CONF" ]; then
    PG_CONF=$(find /var/lib /etc -name "postgresql.conf" 2>/dev/null | head -n 1)
fi

[ -z "$PG_CONF" ] && echo "Ошибка: postgresql.conf не найден!" && exit 1
echo "Конфиг найден: $PG_CONF"

# 3. БЭКАП В ТЕКУЩУЮ ПАПКУ
BACKUP_FILE="./postgresql.conf.backup.$(date +%F_%H%M%S)"
cp "$PG_CONF" "$BACKUP_FILE"
echo "Оригинальный конфиг скопирован в: $BACKUP_FILE"

# 4. Оптимизация
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SHARED_BUFF="$((TOTAL_RAM_KB / 4))kB"
MAX_STACK="$(( $(ulimit -s) - 1024 ))kB"

set_pg_param() {
    grep -q "^#*$1" "$PG_CONF" && sed -i "s|^#*$1 *=.*|$1 = $2|" "$PG_CONF" || echo "$1 = $2" >> "$PG_CONF"
}

set_pg_param "shared_buffers" "'$SHARED_BUFF'"
set_pg_param "max_stack_depth" "'$MAX_STACK'"
set_pg_param "temp_buffers" "'24MB'"
set_pg_param "work_mem" "'16MB'"
set_pg_param "max_connections" "151"
set_pg_param "max_parallel_workers_per_gather" "0"
set_pg_param "maintenance_work_mem" "'128MB'"
set_pg_param "standard_conforming_strings" "on"

# 5. SQL и перезапуск
systemctl restart postgresql 2>/dev/null || systemctl restart postgrespro 2>/dev/null
sudo -u postgres psql <<EOF
-- KSC
CREATE USER kscdbadmin WITH PASSWORD '$PASSDB';
CREATE DATABASE kav OWNER kscdbadmin;
GRANT ALL PRIVILEGES ON DATABASE kav TO kscdbadmin;
\c kav
GRANT USAGE, CREATE ON SCHEMA public TO kscdbadmin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO kscdbadmin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO kscdbadmin;

-- IAM
CREATE USER iamdbadmin WITH PASSWORD '$PASSDBIAM';
CREATE DATABASE iam OWNER iamdbadmin;
GRANT ALL PRIVILEGES ON DATABASE iam TO iamdbadmin;
\c iam
GRANT USAGE, CREATE ON SCHEMA public TO iamdbadmin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO iamdbadmin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO iamdbadmin;
EOF

echo "Настройка завершена. Пароли в $PASS_FILE, бэкап в $BACKUP_FILE"