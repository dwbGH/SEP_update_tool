#!/usr/bin/env bash
#
# SePlatform Deploy Tool — Linux (.deb)
# Установка, обновление и удаление .deb-компонентов SePlatform по whitelist
# из manifest-linux.json. Аналог Windows-инструмента Deploy.ps1.
#
# Дополнительно: управление копиями SePlatform.Data Server (ServerCopies.sh, systemd).

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
DEFAULT_CONFIG="$SCRIPT_DIR/config-linux.json"
DEFAULT_MANIFEST="$SCRIPT_DIR/manifest-linux.json"
SERVER_COPIES_SCRIPT="$SCRIPT_DIR/ServerCopies.sh"

for m in common catalog inventory ops; do
    [ -f "$LIB_DIR/$m.sh" ] || {
        printf 'ERROR: required module not found: %s\n' "$LIB_DIR/$m.sh" >&2
        exit 4
    }
    # shellcheck disable=SC1090
    . "$LIB_DIR/$m.sh"
done

ARCHIVE=''
CONFIG="$DEFAULT_CONFIG"
MANIFEST="$DEFAULT_MANIFEST"
LOG_PATH=''
GLOBAL_LOCALE=''
KEEP_TEMP=0
DRY_RUN=0
AUTO_APPROVE=0
NON_INTERACTIVE=0
MODE_UNINSTALL=0
MODE_UPDATE_ONLY=0
MODE_SERVER_COPIES=0

CFG_ARCH_LIST='amd64|x86_64|all|any'
SESSION_START=''

usage() {
    cat <<EOF
SePlatform Deploy Tool — Linux (.deb)

Usage: $(basename "$0") [options]

Options:
  -a, --archive PATH     Источник: ZIP-архив или папка с *.deb
  -c, --config PATH      Файл конфигурации (default: $DEFAULT_CONFIG)
  -m, --manifest PATH    Файл манифеста/whitelist (default: $DEFAULT_MANIFEST)
  -L, --log-path DIR     Корневая директория логов (default: из config)
  -l, --locale LOC       Предпочтение локали, например ru_RU или en_US
  -n, --dry-run          Сухой прогон: только план, без изменений
  -y, --auto-approve     Не запрашивать подтверждение
  -q, --non-interactive  Без интерактивных запросов
  -u, --update-only      Обновлять только установленные (MISSING пропустить)
  -U, --uninstall        Режим удаления установленных компонентов
  -s, --server-copies    Управление дополнительными копиями Data Server (ServerCopies.sh)
  -k, --keep-temp        Не удалять временную директорию с .deb
  -h, --help             Эта справка

Exit codes:
  0 — успех; 1 — завершено с ошибками; 2 — отменено пользователем;
  3 — критические зависимости; 4 — ошибка параметров/конфигурации.
EOF
}

# ---------- разбор аргументов ----------

opts=$(getopt -o a:c:m:L:l:nyquUskh \
    --long archive:,config:,manifest:,log-path:,locale:,dry-run,auto-approve,non-interactive,update-only,uninstall,server-copies,keep-temp,help \
    -n "$(basename "$0")" -- "$@") || { usage; exit 4; }
eval set -- "$opts"
while true; do
    case "$1" in
        -a | --archive) ARCHIVE="$2"; shift 2 ;;
        -c | --config) CONFIG="$2"; shift 2 ;;
        -m | --manifest) MANIFEST="$2"; shift 2 ;;
        -L | --log-path) LOG_PATH="$2"; shift 2 ;;
        -l | --locale) GLOBAL_LOCALE="$2"; shift 2 ;;
        -n | --dry-run) DRY_RUN=1; shift ;;
        -y | --auto-approve) AUTO_APPROVE=1; shift ;;
        -q | --non-interactive) NON_INTERACTIVE=1; shift ;;
        -u | --update-only) MODE_UPDATE_ONLY=1; shift ;;
        -U | --uninstall) MODE_UNINSTALL=1; shift ;;
        -s | --server-copies) MODE_SERVER_COPIES=1; shift ;;
        -k | --keep-temp) KEEP_TEMP=1; shift ;;
        -h | --help) usage; exit 0 ;;
        --) shift; break ;;
        *) usage; exit 4 ;;
    esac
done
[ $# -eq 0 ] || { usage; exit 4; }

[ -f "$CONFIG" ] || fatal "config not found: $CONFIG"
require_json_tool || exit 4
load_config "$CONFIG"
[ -n "$LOG_PATH" ] || LOG_PATH="${CFG['logRoot']}"

for tool in bash dpkg dpkg-query dpkg-deb python3; do
    command -v "$tool" >/dev/null 2>&1 || fatal "required tool not found: $tool"
done

check_python3() {
    # скрипты используют stdlib Python 3 (json, argparse-подобные heredoc-парсеры)
    local v
    v=$(python3 --version 2>&1) || { err 'python3 is not runnable'; return 1; }
    case "$v" in
        Python\ 3.*) return 0 ;;
    esac
    err "Python 3 required, found: $v"
    return 1
}
check_python3 || exit $EXIT_BAD_PARAMS

require_root_safe() {
    if [ "${DRY_RUN}" -ne 1 ] && [ "$(cfg_bool requireRoot 1)" = '1' ]; then
        if [ "$(id -u)" -ne 0 ]; then
            err 'Требуются права root (dpkg и systemd). Запустите с sudo.'
            exit 4
        fi
    fi
}

if [ "$MODE_SERVER_COPIES" -eq 1 ]; then
    if [ -x "$SERVER_COPIES_SCRIPT" ] || [ -f "$SERVER_COPIES_SCRIPT" ]; then
        /usr/bin/env bash "$SERVER_COPIES_SCRIPT"
        exit $?
    fi
    fatal "ServerCopies.sh not found: $SERVER_COPIES_SCRIPT"
fi

# ---------- мастер запуска (если нет параметров режима) ----------

interactive_startup=$(( (MODE_UNINSTALL == 0) && (MODE_UPDATE_ONLY == 0) && (NON_INTERACTIVE == 0) && (DRY_RUN == 0) && (AUTO_APPROVE == 0) ))

if [ "$interactive_startup" -eq 1 ] && [ -z "$ARCHIVE" ]; then
    default_arch="${CFG['defaultArchive']:-}"
    say ''
    say 'SePlatform Deploy Tool (Linux)'
    say '=============================='
    say ''
    say 'What do you want to do?'
    say ''
    say '  [1] Install/update components from source (ZIP or folder of .deb)'
    say '  [2] Manage additional SePlatform.Data Server copies (systemd)'
    say '  [3] Exit'
    say ''
    printf 'Select (1, 2 or 3): '
    read -r choice || { say 'Bye.'; exit $EXIT_ABORTED; }
    case "$choice" in
        2)
            /usr/bin/env bash "$SERVER_COPIES_SCRIPT"
            exit $?
            ;;
        3) say 'Bye.'; exit $EXIT_ABORTED ;;
        1) ;;
        *)
            say 'Please enter 1-3.' >&2
            exit $EXIT_BAD_PARAMS
            ;;
    esac
    if [ -z "$ARCHIVE" ]; then
        if [ -n "$default_arch" ]; then
            printf 'Path to archive [default: %s]: ' "$default_arch"
        else
            printf 'Path to archive (ZIP or folder of .deb): '
        fi
        read -r ans || exit $EXIT_ABORTED
        if [ -n "$ans" ]; then ARCHIVE="$ans"; else ARCHIVE="$default_arch"; fi
    fi
fi

[ -n "$ARCHIVE" ] || fatal 'Archive path was not provided. Use -a/--archive.'

resolve_abs() {
    case "$1" in
        /*) echo "$1" ;;
        *) echo "$PWD/$1" ;;
    esac
}
SOURCE=$(resolve_abs "$ARCHIVE")
SOURCE_DISPLAY=$(basename "$SOURCE")
detect_source_type "$SOURCE"

require_root_safe

# ---------- сессия ----------

SESSION_START=$(date '+%Y-%m-%d %H:%M:%S')
new_session "$LOG_PATH" "$(basename "$SOURCE")" || exit $EXIT_BAD_PARAMS
log "Mode: default (install and update)"
log "Source: $SOURCE ($SOURCE_TYPE)"
log "OS: $(get_machine_os)"

TEMP_ROOT="${CFG['tempRoot']:-/tmp/SePlatform-Deploy}"
TEMP_SESSION="$TEMP_ROOT/$(date '+%Y%m%d_%H%M%S')"
DEB_TMP_DIR="$TEMP_SESSION/deb"
mkdir -p "$DEB_TMP_DIR" || { err "cannot create temp dir: $DEB_TMP_DIR"; exit $EXIT_BAD_PARAMS; }

CFG_ARCH_LIST="${CFG['preferArch']}"
load_manifest "$MANIFEST"
collect_entries

dpkg_inventory
build_actions
apply_status_from_deps

# снимок установленных версий до изменений (для поля oldVersion в отчёте)
declare -a INST_VER_ORIG=()
for _x in "${!PRODUCTS[@]}"; do INST_VER_ORIG[$_x]="${INST_VER[$_x]}"; done

# вендорские переименования пакетов: pkg -> pkg_ru_ru (локализованные сборки)
# dpkg считает такой .deb новым пакетом и отказывается перезаписывать файлы старого,
# поэтому перед установкой старый пакет-владелец нужно снять
declare -a PREV_PKG=()
MISSING_COUNT=0
MISSING_WARN_LOGGED=0
declare -a MISSING_ROWS=()
mark_renames() {
    local idx
    for idx in "${!PRODUCTS[@]}"; do
        PREV_PKG[$idx]=''
        if [ "${STATUS[$idx]}" = 'UPDATE' ] && [ -n "${INST_PKG[$idx]}" ] && [ -n "${CAND_PKG[$idx]}" ] &&
            [ "${INST_PKG[$idx],,}" != "${CAND_PKG[$idx],,}" ]; then
            PREV_PKG[$idx]="${INST_PKG[$idx]}"
        fi
    done
}
mark_renames

collect_not_installed() {
    local idx
    MISSING_COUNT=0
    MISSING_ROWS=()
    for idx in "${!PRODUCTS[@]}"; do
        case "${STATUS[$idx]}" in
            MISSING | NO_DEB)
                MISSING_COUNT=$((MISSING_COUNT + 1))
                MISSING_ROWS+=("  [${STATUS[$idx]}] $(prod_val "$idx" 1)  (candidate: ${CAND_VER[$idx]:-no .deb in source})")
                ;;
            BLOCKED)
                MISSING_COUNT=$((MISSING_COUNT + 1))
                MISSING_ROWS+=("  [BLOCKED] $(prod_val "$idx" 1)  -  ${BLOCKED_REASON[$idx]}")
                ;;
        esac
    done
}

# громкое предупреждение, если не установлено больше порога компонентов
show_missing_warning() {
    local thr="$1"
    [ "$MISSING_COUNT" -gt "$thr" ] || return 0
    say ''
    say '=================================================='
    say "  !! ВНИМАНИЕ: НЕ УСТАНОВЛЕНО $MISSING_COUNT КОМПОНЕНТОВ !!"
    say "     (порог предупреждения: $thr)"
    say '=================================================='
    printf '%s\n' "${MISSING_ROWS[@]}"
    say ''
    say 'Эти компоненты НЕ будут установлены и останутся в прежней версии.'
    say 'Установите недостающие системные пакеты и повторите развёртывание'
    say 'в режиме [2] (install and update), либо выберите [1], чтобы обновить'
    say 'только то, что уже установлено.'
    say ''
    if [ "${MISSING_WARN_LOGGED:-0}" != '1' ]; then
        MISSING_WARN_LOGGED=1
        local joined
        joined=$(printf '%s\n' "${MISSING_ROWS[@]}" | tr -s ' ' | tr '\n' ';')
        warn "NOT INSTALLED: $MISSING_COUNT of ${#PRODUCTS[@]} components (threshold $thr): ${joined%;}"
    fi
}

# ---------- план ----------

build_report_rows() {
    REPORT_ROWS=()
    local idx
    for idx in "${!PRODUCTS[@]}"; do
        local f
        f=$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
            "$(prod_val "$idx" 0)" "$(prod_val "$idx" 1)" "${STATUS[$idx]}" \
            "${INST_PKG[$idx]}" "${INST_VER_ORIG[$idx]}" "${CAND_VER[$idx]}" \
            "${CAND_BASE[$idx]}" "${INSTALL_EXIT[$idx]:-}" "${UNINSTALL_EXIT[$idx]:-}" \
            "${VERIFIED_OK[$idx]:-0}" "${ERROR[$idx]}" "${PREV_PKG[$idx]:-}")
        REPORT_ROWS+=("$f")
    done
}

emit_report() {
    # emit_report EXIT_CODE RESULT
    export SESSION_START SESSION_END DEPLOY_MODE SOURCE_DISPLAY SOURCE_TYPE DRY_RUN \
        CountUpdated CountInstalled CountUninstalled CountSkipped CountFailed CountOk
    SESSION_END=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s\n' "${REPORT_ROWS[@]}" > "$SESSION_DIR/components.tsv"
    write_report "$1" "$2"
}

show_summary() {
    local exit_code="$1"
    say ''
    say '========================================'
    say 'DEPLOYMENT SUMMARY'
    say '========================================'
    say ''
    printf 'Updated:   %s\n' "$CountUpdated"
    printf 'Installed: %s\n' "$CountInstalled"
    printf 'Uninstalled: %s\n' "$CountUninstalled"
    printf 'Skipped:   %s\n' "$CountSkipped"
    printf 'Failed:    %s\n' "$CountFailed"
    printf 'Not installed at start: %s\n' "$MISSING_COUNT"
    say ''
    local idx
    for idx in "${!PRODUCTS[@]}"; do
        case "${STATUS[$idx]}" in
            OK | UPDATE | INSTALL) say "  [OK] $(prod_val "$idx" 1)" ;;
            SKIP | SKIP_NEWER | NO_DEB) say "  [SKIP] $(prod_val "$idx" 1)" ;;
            ERROR | BLOCKED) say "  [ERROR] $(prod_val "$idx" 1)" ;;
            UNINSTALLED) say "  [UNINSTALLED] $(prod_val "$idx" 1)" ;;
            ABORTED) say "  [ABORTED] $(prod_val "$idx" 1)" ;;
            *) say "  [${STATUS[$idx]}] $(prod_val "$idx" 1)" ;;
        esac
    done
    say ''
    printf 'Logs: %s\n' "$SESSION_DIR"
    printf 'Report: %s\n' "$REPORT_FILE"
    say ''
    printf 'Exit code: %s\n' "$exit_code"
}

show_plan() {
    say ''
    say 'SePlatform Deployment Tool (Linux)'
    say '===================================='
    say ''
    printf 'Source: %s (%s)\n' "$SOURCE" "$SOURCE_TYPE"
    printf 'OS:     %s\n' "$(get_machine_os)"
    say ''
    say 'Changes:'
    say ''
    local idx name st old new tag lines=0
    for idx in "${!PRODUCTS[@]}"; do
        name=$(prod_val "$idx" 1)
        st="${STATUS[$idx]}"
        old="${INST_VER[$idx]}"; new="${CAND_VER[$idx]}"
        case "$st" in
            UPDATE) tag=' [UPDATE]';;
            INSTALL) tag=' [INSTALL]';;
            MISSING) tag=' [MISSING]';;
            OK) tag=' [OK]';;
            SKIP_NEWER) tag=' [SKIP]';;
            NO_DEB) tag=' [SKIP]';;
            BLOCKED) tag=' [BLOCKED]';;
            *) tag=" [$st]";;
        esac
        case "$st" in
            UPDATE) printf '%s %s\n           %s -> %s\n' "$tag" "$name" "$old" "$new" ;;
            INSTALL) printf '%s %s\n           %s\n' "$tag" "$name" "$new" ;;
            OK) printf '%s %s\n           %s\n' "$tag" "$name" "$new" ;;
            MISSING) printf '%s %s\n           %s\n' "$tag" "$name" "not installed (candidate $new)" ;;
            SKIP_NEWER) printf '%s %s\n           installed newer than archive (%s)\n' "$tag" "$name" "$old" ;;
            NO_DEB) printf '%s %s\n           no .deb in source\n' "$tag" "$name" ;;
            BLOCKED) printf '%s %s\n           %s\n' "$tag" "$name" "${BLOCKED_REASON[$idx]}" ;;
            *) printf '%s %s\n' "$tag" "$name" ;;
        esac
        if [ -n "${PREV_PKG[$idx]}" ]; then
            printf '           package renamed: %s -> %s (old package removed first)\n' \
                "${PREV_PKG[$idx]}" "${CAND_PKG[$idx]}"
        fi
        lines=$((lines + 1))
    done
    [ "$lines" -gt 0 ] || say '  Nothing to do.'
    local dep_seen=0
    for idx in "${!PRODUCTS[@]}"; do
        [ -n "${DEP_CHECK_TEXT[$idx]}" ] || continue
        [ "$dep_seen" = '1' ] || { say ''; say 'Dependencies:'; dep_seen=1; }
        printf '%s' "${DEP_CHECK_TEXT[$idx]}" | while IFS= read -r dl; do say "  $dl"; done
    done
    say ''
}

show_plan

collect_not_installed
MISSING_WARN=$(cfg_int missingWarnThreshold 3)
show_missing_warning "$MISSING_WARN"

if [ "$DRY_RUN" -eq 1 ]; then
    log 'Dry run: no changes were made'
    if [ "$KEEP_TEMP" -eq 0 ] && [ "$(cfg_bool cleanupTempOnSuccess 1)" = '1' ]; then
        rm -rf "$TEMP_SESSION" 2>/dev/null
        log "Temporary files removed: $TEMP_SESSION"
    fi
    build_report_rows
    DEPLOY_MODE='DRY_RUN'
    emit_report "$EXIT_OK" 'DRY_RUN'
    say ''
    say "Logs: $SESSION_DIR"
    exit $EXIT_OK
fi

# ---------- выбор режима ----------

DEPLOY_MODE=''
if [ "$MODE_UNINSTALL" -eq 1 ]; then
    DEPLOY_MODE='UNINSTALL'
elif [ "$MODE_UPDATE_ONLY" -eq 1 ]; then
    DEPLOY_MODE='UPDATE'
elif [ "$AUTO_APPROVE" -eq 1 ] || [ "$NON_INTERACTIVE" -eq 1 ]; then
    DEPLOY_MODE='INSTALL'
else
    say 'Deployment mode:'
    say '  [1] Update existing components (do not install missing)'
    say '  [2] Install and update (including missing components)'
    say '  [3] Uninstall components'
    say '  [4] Exit'
    say ''
    printf 'Select (1, 2, 3 or 4): '
    read -r mode || { mode=4; }
    case "$mode" in
        1) DEPLOY_MODE='UPDATE' ;;
        2) DEPLOY_MODE='INSTALL' ;;
        3) DEPLOY_MODE='UNINSTALL' ;;
        4) exit $EXIT_ABORTED ;;
        *) err 'Invalid mode'; exit $EXIT_BAD_PARAMS ;;
    esac
fi
log "Deployment mode: $DEPLOY_MODE"

# ---------- сборка списка действий ----------

build_target_sets() {
    local idx
    OFFER_IX=(); OFFER_LABELS=()
    case "$DEPLOY_MODE" in
        UNINSTALL)
            for idx in "${!PRODUCTS[@]}"; do
                [ "${INST_PKG[$idx]:-}" ] || continue
                OFFER_IX+=("$idx")
                OFFER_LABELS+=("$(prod_val "$idx" 1)  ${INST_VER[$idx]}  (${INST_PKG[$idx]})")
            done
            ;;
        UPDATE)
            for idx in "${!PRODUCTS[@]}"; do
                case "${STATUS[$idx]}" in
                    MISSING)
                        STATUS[$idx]='SKIP'
                        ERROR[$idx]='Not installed; update-only mode'
                        log "$(prod_val "$idx" 1): not installed, skipped (update-only)"
                        ;;
                    UPDATE)
                        OFFER_IX+=("$idx")
                        OFFER_LABELS+=("$(prod_val "$idx" 1)  ${INST_VER[$idx]} -> ${CAND_VER[$idx]}")
                        ;;
                esac
            done
            ;;
        *)
            for idx in "${!PRODUCTS[@]}"; do
                if [ "${STATUS[$idx]}" = 'MISSING' ]; then
                    STATUS[$idx]='INSTALL'
                    log "$(prod_val "$idx" 1): selected for install"
                fi
            done
            for idx in "${!PRODUCTS[@]}"; do
                case "${STATUS[$idx]}" in
                    UPDATE | INSTALL)
                        OFFER_IX+=("$idx")
                        if [ "${STATUS[$idx]}" = 'INSTALL' ]; then
                            OFFER_LABELS+=("$(prod_val "$idx" 1)  ${CAND_VER[$idx]}  [not installed]")
                        else
                            OFFER_LABELS+=("$(prod_val "$idx" 1)  ${INST_VER[$idx]} -> ${CAND_VER[$idx]}")
                        fi
                        ;;
                esac
            done
            ;;
    esac
}

build_target_sets

DO_IX=()
if [ ${#OFFER_IX[@]} -gt 0 ] && [ "$AUTO_APPROVE" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
    title='Components to install/update'
    case "$DEPLOY_MODE" in
        UNINSTALL) title='Components to uninstall' ;;
        UPDATE) title='Components to update' ;;
    esac
    if choose_items "$title" "${OFFER_LABELS[@]}"; then
        for _si in "${SELECTED[@]}"; do DO_IX+=("${OFFER_IX[_si]}"); done
    else
        log 'No components selected'
        build_report_rows
        emit_report "$EXIT_ABORTED" 'ABORTED'
        exit $EXIT_ABORTED
    fi
elif [ ${#OFFER_IX[@]} -gt 0 ]; then
    DO_IX=("${OFFER_IX[@]}")
fi

if [ "${#DO_IX[@]}" -gt 0 ]; then
    if [ "$AUTO_APPROVE" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
        say '================================'
        if [ "$MISSING_COUNT" -gt "$MISSING_WARN" ]; then
            show_missing_warning "$MISSING_WARN"
        fi
        confirm_msg='Continue'
        if [ "$MISSING_COUNT" -gt 0 ]; then
            confirm_msg="Continue (WARNING: $MISSING_COUNT components are NOT installed)"
        fi
        if ! ask_yes_no "$confirm_msg"; then
            log 'Deployment aborted by user'
            build_report_rows
            emit_report "$EXIT_ABORTED" 'ABORTED'
            exit $EXIT_ABORTED
        fi
        say ''
    fi
fi

# сортировка по (order, id) для стабильности
ORDERED_DO=()
if [ ${#DO_IX[@]} -gt 0 ]; then
    i=0
    for _do in "${DO_IX[@]}"; do
        ORDERED_DO[$i]=$(prod_val "$_do" 8)"|$(prod_val "$_do" 0)|$_do"
        i=$((i + 1))
    done
    mapfile -t ORDERED_DO < <(printf '%s\n' "${ORDERED_DO[@]}" | sort -n -t'|' -k1,1 -k2,2)
fi

# ---------- выполнение ----------

declare -a INSTALL_EXIT=() UNINSTALL_EXIT=() VERIFIED_OK=()

run_install() {
    local idx="$1" id name file rc plog
    id=$(prod_val "$idx" 0); name=$(prod_val "$idx" 1)
    say ''
    if [ "${STATUS[$idx]}" = 'UPDATE' ]; then
        say ">>> [UPDATE] $name  ${INST_VER[$idx]} -> ${CAND_VER[$idx]}"
    else
        say ">>> [INSTALL] $name  ${CAND_VER[$idx]}"
    fi
    log "Action started: $id status=${STATUS[$idx]}"

    local svcs; svcs=$(prod_services "$idx")
    local procs; procs=$(prod_processes "$idx")
    [ -z "$svcs" ] || stop_services "$svcs"
    [ -z "$procs" ] || stop_processes "$procs"

    if ! extract_candidate "$idx" "$DEB_TMP_DIR"; then
        STATUS[$idx]='ERROR'; ERROR[$idx]="Failed to extract candidate"
        INSTALL_EXIT[$idx]='9998'
        return 1
    fi
    file="${CAND_PATH[$idx]}"
    plog="$SESSION_DIR/$id-install.log"

    # переименование пакета вендором (pkg -> pkg_ru_ru в локализованных сборках):
    # для dpkg это новый пакет, поэтому он отказывается перезаписывать файлы
    # старого. Снимаем старый пакет-владелец, оставляя конфиги (dpkg -r).
    local -a dpkg_extra=()
    if [ -n "${PREV_PKG[$idx]:-}" ]; then
        say "  [i] package renamed: ${PREV_PKG[$idx]} -> ${CAND_PKG[$idx]}"
        log "Package renamed: ${PREV_PKG[$idx]} -> ${CAND_PKG[$idx]}; removing previous owner before install"
        if dpkg_remove_package "${PREV_PKG[$idx]}" "$plog" "${CFG['uninstallTimeoutSeconds']:-600}" remove; then
            log "Previous package removed: ${PREV_PKG[$idx]}"
        else
            warn "cannot remove previous package ${PREV_PKG[$idx]}: install may fail on file conflicts"
            say "  [!] previous package ${PREV_PKG[$idx]} was NOT removed cleanly"
        fi
        # оставшиеся conffiles от старого пакета не должны блокировать установку
        dpkg_extra=(--force-confdef)
    fi

    dpkg_install_file "$file" "$plog" "${CFG['installTimeoutSeconds']:-1800}" \
        ${dpkg_extra[@]+"${dpkg_extra[@]}"}
    rc=$?
    INSTALL_EXIT[$idx]=$rc
    append_to_log "$plog" "dpkg install exit code: $rc"

    # конфликт файлов с другим пакетом: повтор с --force-overwrite
    if [ "$rc" -ne 0 ] && deb_install_conflict "$plog"; then
        warn "$name: file conflict while unpacking, retrying with --force-overwrite"
        say "  [i] file conflict, retry with --force-overwrite"
        dpkg_install_file "$file" "$plog" "${CFG['installTimeoutSeconds']:-1800}" \
            ${dpkg_extra[@]+"${dpkg_extra[@]}"} --force-overwrite
        rc=$?
        INSTALL_EXIT[$idx]=$rc
        append_to_log "$plog" "dpkg install --force-overwrite exit code: $rc"
    fi

    if [ "$rc" -eq 0 ]; then
        if verify_installed "$idx"; then
            STATUS[$idx]='OK'; VERIFIED_OK[$idx]=1
            if [ "${STATUS_ORIG[$idx]:-}" = 'UPDATE' ]; then CountUpdated=$((CountUpdated + 1)); else CountInstalled=$((CountInstalled + 1)); fi
            say "  [OK] $name ${CAND_VER[$idx]}"
        else
            STATUS[$idx]='ERROR'; ERROR[$idx]="Verification failed: package ${CAND_PKG[$idx]:-?} not found or version mismatch"
            CountFailed=$((CountFailed + 1))
            say "  [ERROR] ${ERROR[$idx]}"
        fi
    else
        local reason
        reason=$(deb_log_error_summary "$plog")
        STATUS[$idx]='ERROR'
        ERROR[$idx]="dpkg install failed with exit code $rc${reason:+: $reason}"
        CountFailed=$((CountFailed + 1))
        say "  [FAIL] ${ERROR[$idx]}"
    fi

    [ -z "$svcs" ] || start_services "$svcs"
    log "Action completed: $id exit=$rc"
    return $((rc == 0 ? 0 : 1))
}

run_uninstall() {
    local idx="$1" id name pkg rc plog
    id=$(prod_val "$idx" 0); name=$(prod_val "$idx" 1)
    pkg="${INST_PKG[$idx]}"
    say ''
    say ">>> [UNINSTALL] $name  ${INST_VER[$idx]}"
    log "Action started: $id status=UNINSTALL"

    local svcs; svcs=$(prod_services "$idx")
    local procs; procs=$(prod_processes "$idx")
    [ -z "$svcs" ] || stop_services "$svcs"
    [ -z "$procs" ] || stop_processes "$procs"

    plog="$SESSION_DIR/$id-uninstall.log"
    dpkg_remove_package "$pkg" "$plog" "${CFG['uninstallTimeoutSeconds']:-600}"
    rc=$?
    UNINSTALL_EXIT[$idx]=$rc
    append_to_log "$plog" "dpkg remove exit code: $rc"

    if [ "$rc" -eq 0 ]; then
        if verify_uninstalled "$idx"; then
            STATUS[$idx]='UNINSTALLED'; VERIFIED_OK[$idx]=1
            CountUninstalled=$((CountUninstalled + 1))
            say "  [OK] $name uninstalled"
        else
            STATUS[$idx]='ERROR'; ERROR[$idx]="Verification failed: package $pkg still installed"
            CountFailed=$((CountFailed + 1))
            say "  [ERROR] ${ERROR[$idx]}"
        fi
    else
        STATUS[$idx]='ERROR'; ERROR[$idx]="dpkg remove failed with exit code $rc"
        CountFailed=$((CountFailed + 1))
        say "  [FAIL] ${ERROR[$idx]}"
    fi
    log "Action completed: $id exit=$rc"
    return $((rc == 0 ? 0 : 1))
}

verify_installed() {
    local idx="$1" want="${CAND_PKG[$idx]}" expected="${CAND_VER[$idx]}" hit latest=''
    dpkg_inventory
    if [ -z "$want" ]; then return 0; fi
    local h
    for h in $(find_installed_by_package "$want"); do
        [ -z "$latest" ] || dpkg --compare-versions "${INV_VER[$h]}" gt "$latest" 2>/dev/null || continue
        latest="${INV_VER[$h]}"
    done
    [ -n "$latest" ] || return 1
    if [ -n "$expected" ]; then
        dpkg --compare-versions "$latest" eq "$expected" 2>/dev/null || return 1
    fi
    INST_PKG[$idx]="$want"; INST_VER[$idx]="$latest"
    return 0
}

verify_uninstalled() {
    local idx="$1" pkg="${INST_PKG[$idx]}" h
    dpkg_inventory
    for h in $(find_installed_by_package "$pkg"); do
        return 1
    done
    INST_PKG[$idx]=''; INST_VER[$idx]=''
    return 0
}

CountUpdated=0; CountInstalled=0; CountUninstalled=0; CountSkipped=0; CountFailed=0; CountOk=0

# фиксируем исходный статус для счётчика Install/Update
declare -a STATUS_ORIG=()
for _x in "${!PRODUCTS[@]}"; do STATUS_ORIG[$_x]="${STATUS[$_x]}"; done

if [ ${#ORDERED_DO[@]} -gt 0 ]; then
    for _do_e in "${ORDERED_DO[@]}"; do
        _di=${_do_e##*|}
        if [ "$DEPLOY_MODE" = 'UNINSTALL' ]; then
            run_uninstall "$_di"
        else
            run_install "$_di"
        fi
    done
else
    log 'Nothing to do.'
fi

# счётчики по финальным статусам
for _x in "${!PRODUCTS[@]}"; do
    case "${STATUS[$_x]}" in
        OK) CountOk=$((CountOk + 1)) ;;
        SKIP | SKIP_NEWER | NO_DEB) : ;;  # уже учли как skipped
    esac
done

# подсчёт SKIP/NO_DEB/BLOCKED в CountSkipped/CountFailed
for _x in "${!PRODUCTS[@]}"; do
    case "${STATUS[$_x]}" in
        SKIP | SKIP_NEWER | NO_DEB) CountSkipped=$((CountSkipped + 1)) ;;
        BLOCKED) CountFailed=$((CountFailed + 1)) ;;
    esac
done

has_failed=$((CountFailed > 0 ? 1 : 0))
if [ "$has_failed" -eq 1 ]; then
    result='COMPLETED_WITH_ERRORS'; exit_code=$EXIT_ERRORS
else
    result='SUCCESS'; exit_code=$EXIT_OK
fi

cleanup_temp() {
    if [ "$has_failed" -eq 1 ] && [ "$(cfg_bool keepTempOnError 0)" = '1' ]; then
        log "Temporary files kept (keepTempOnError): $TEMP_SESSION"
        return
    fi
    if [ "$KEEP_TEMP" -eq 1 ]; then
        log "Temporary files kept (-k/--keep-temp): $TEMP_SESSION"
        return
    fi
    if [ "$has_failed" -eq 0 ] && [ "$(cfg_bool cleanupTempOnSuccess 1)" = '1' ]; then
        rm -rf "$TEMP_SESSION" 2>/dev/null
        log "Temporary files removed: $TEMP_SESSION"
    fi
}
cleanup_temp

build_report_rows
emit_report "$exit_code" "$result"

show_summary "$exit_code"
exit "$exit_code"