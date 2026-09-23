# ops.sh — остановка/запуск служб и процессов, установка/удаление .deb.

run_timed() {
    # run_timed SECONDS EXTRA_LOG CMD...  -> exit code; вывод в Deployment.log, EXTRA_LOG и консоль
    local sec="$1" extra="$2" rc logfd
    shift 2
    logfd=3
    eval "exec ${logfd}>&1"
    timeout -k 10 "$sec" "$@" 2>&1 | tee -a "$LOG_FILE" -a "$extra" >&${logfd}
    rc=${PIPESTATUS[0]}
    eval "exec ${logfd}>&-"
    return "$rc"
}

unit_normalize() {
    # unit_normalize NAME -> name.service
    local u="$1"
    [[ "$u" == *.service ]] || u="${u}.service"
    echo "$u"
}

unit_inactive() {
    local u; u=$(unit_normalize "$1")
    systemctl is-active --quiet "$u" 2>/dev/null || return 0
    return 1
}

stop_services() {
    # stop_services 'unit1 unit2'
    local svc u
    for svc in $1; do
        [ -n "$svc" ] || continue
        u=$(unit_normalize "$svc")
        [ -f "/etc/systemd/system/$u" ] || [ -f "/lib/systemd/system/$u" ] || { warn "service unit not found, skipping: $u"; continue; }
        if ! unit_inactive "$u"; then
            log "Stopping service: $u"
            systemctl stop "$u" >/dev/null 2>&1 || warn "cannot stop $u"
        fi
    done
}

start_services() {
    # start_services 'unit1 unit2'   (запускает только существующие юниты)
    local svc u
    for svc in $1; do
        [ -n "$svc" ] || continue
        u=$(unit_normalize "$svc")
        if [ -f "/etc/systemd/system/$u" ] || [ -f "/lib/systemd/system/$u" ]; then
            log "Starting service: $u"
            systemctl start "$u" >/dev/null 2>&1 || warn "cannot start $u"
        fi
    done
}

stop_processes() {
    # stop_processes 'name1 name2'
    local p pid
    for p in $1; do
        [ -n "$p" ] || continue
        while pid=$(pgrep -x -- "$p" 2>/dev/null | head -n1); [ -n "$pid" ]; do
            log "Stopping process: $p (pid $pid)"
            kill -TERM "$pid" 2>/dev/null || break
            sleep 1
            pgrep -x -- "$p" >/dev/null 2>&1 || break
            kill -KILL "$pid" 2>/dev/null || break
        done
    done
}

dpkg_install_file() {
    # dpkg_install_file FILE LOG SECONDS  -> install exit code
    local file="$1" plog="$2" sec="$3" rc=0 mode
    mode='dpkg'
    if [ "$(cfg_bool installWithApt 0)" = '1' ]; then
        mode='apt'
        run_timed "$sec" "$plog" apt-get install -y "./$file"
        rc=$?
    else
        run_timed "$sec" "$plog" dpkg -i "$file"
        rc=$?
    fi
    if [ "$rc" = '124' ]; then
        printf '%s [ERROR] %s timed out\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" >> "$plog"
    fi
    return "$rc"
}

dpkg_remove_package() {
    # dpkg_remove_package PKG LOG SECONDS  -> remove exit code
    local pkg="$1" plog="$2" sec="$3" rc=0 op='remove'
    if [ "$(cfg_bool purgeOnUninstall 0)" = '1' ]; then
        op='purge'
        run_timed "$sec" "$plog" dpkg -P "$pkg"
    else
        run_timed "$sec" "$plog" dpkg -r "$pkg"
    fi
    rc=$?
    if [ "$rc" = '124' ]; then
        printf '%s [ERROR] %s timed out\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$op" >> "$plog"
    fi
    return "$rc"
}

# потоки для записи отдельного лога компонента
append_to_log() {
    local f="$1"; shift
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$f"
}