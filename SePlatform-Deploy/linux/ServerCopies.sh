#!/usr/bin/env bash

SERVER_ROOT="${SERVER_ROOT:-/opt/SePlatform}"
MAIN_FOLDER="${MAIN_FOLDER:-SePlatform.Server}"
XML_NAME="${XML_NAME:-SePlatform.Server.xml}"
JSON_NAME="${JSON_NAME:-SePlatform.Server.json}"
EXE_NAME="${EXE_NAME:-SePlatform.Server}"
UNIT_DIR="${UNIT_DIR:-/lib/systemd/system}"

META=()

NONE=''
ESC=$(printf '\033')
NO_COLOR=0

say() { printf '%s\n' "$*"; }
log() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

ok() { printf '  [OK] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

svc_unit() { printf '%s.service' "${1,,}"; }

xml_attr() {
    local file="$1" elem="$2" attr="$3"
    grep -oP "<${elem}[^>]*${attr}=\"\K[^\"]*" "$file" 2>/dev/null | head -n1
}

set_xml_attr() {
    local file="$1" elem="$2" attr="$3" value="$4"
    sed -i -E "s|(<${elem}[^>]*${attr}=\")[^\"]*|\\1${value}|" "$file" 2>/dev/null
}

json_read_id() {
    local file="$1"
    if [ -f "$file" ]; then
        grep -oP '"Id"\s*:\s*"\K[^"]*' "$file" 2>/dev/null | head -n1
    fi
}

json_write_id() {
    local file="$1" id="$2"
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")"
        printf '{\n  "Version": 0,\n  "Instance": {\n    "Id": "%s"\n  }\n}\n' "$id" > "$file"
        return 0
    fi
    if grep -q '"Instance"' "$file"; then
        if grep -q '"Id"' "$file"; then
            sed -i -E "s|(\"Id\"\s*:\s*\")[^\"]*|\\1${id}|" "$file"
        else
            sed -i -E "s|(\"Instance\"\s*:\s*\{)|\1 \"Id\": \"${id}\"|" "$file"
        fi
    else
        local ver
        ver=$(grep -oP '"Version"\s*:\s*\K[0-9]+' "$file" | head -n1)
        [ -n "$ver" ] || ver=0
        printf '{\n  "Version": %s,\n  "Instance": {\n    "Id": "%s"\n  }\n}\n' "$ver" "$id" > "$file"
    fi
}

comment_xml_instance() {
    local file="$1"
    if grep -qP '<!--[^>]*<Instance' "$file"; then
        return 0
    fi
    sed -i -E 's|<Instance[^>]*ID="[^"]*".*?</Instance>|<!-- \0 -->|' "$file"
    sed -i -E 's|<Instance[^>]*ID="[^"]*"[^>]*/>|<!-- \0 -->|' "$file"
}

read_inst_id() {
    local dir="$1"
    local id
    id=$(json_read_id "$dir/$JSON_NAME")
    if [ -z "$id" ]; then
        id=$(xml_attr "$dir/$XML_NAME" Instance ID)
    fi
    printf '%s' "$id"
}

unit_belongs_to() {
    local svc="$1" dir="$2"
    local unit
    unit=$(svc_unit "$svc")
    [ -f "$UNIT_DIR/$unit" ] || return 1
    grep -q "ExecStart=${dir}/" "$UNIT_DIR/$unit" 2>/dev/null || return 1
    return 0
}

unit_state() {
    local svc="$1"
    local unit state
    unit=$(svc_unit "$svc")
    [ -f "$UNIT_DIR/$unit" ] || { echo 'not installed'; return; }
    state=$(systemctl is-active "$unit" 2>/dev/null || echo inactive)
    echo "$state"
}

is_main() {
    local name="$1"
    [ "$name" = "$MAIN_FOLDER" ]
}

detect() {
    META=()
    [ -d "$SERVER_ROOT" ] || return 0
    local d name svc port id state
    for d in "$SERVER_ROOT"/"$MAIN_FOLDER"*; do
        [ -d "$d" ] || continue
        [ -f "$d/$EXE_NAME" ] || continue
        [ -f "$d/$XML_NAME" ] || continue
        name=$(basename "$d")
        svc=$(xml_attr "$d/$XML_NAME" install ServiceName)
        port=$(xml_attr "$d/$XML_NAME" Connection Port)
        id=$(read_inst_id "$d")
        state=$(unit_state "$svc")
        META+=("$d|$name|$svc|$port|$id|$state")
    done
if [ ${#META[@]} -gt 1 ]; then
        local main meta tmp=()
        for meta in "${META[@]}"; do
            case "$meta" in
                *"|$MAIN_FOLDER|"*) main="$meta" ;;
                *) tmp+=("$meta") ;;
            esac
        done
        META=()
        [ -n "$main" ] && META+=("$main")
        local sorted
        sorted=$(printf '%s\n' "${tmp[@]}")
        while IFS= read -r line; do
            [ -n "$line" ] && META+=("$line")
        done <<< "$sorted"
    fi
}

show_table() {
    say ''
    say 'SePlatform.Data Server copies (detected):'
    say ''
    if [ ${#META[@]} -eq 0 ]; then
        say '  None found.'
        return
    fi
    local i=1 meta name svc port state tag
    for meta in "${META[@]}"; do
        IFS='|' read -r d name svc port id state <<< "$meta"
        if is_main "$name"; then
            tag='MAIN'
        else
            tag='COPY'
        fi
        printf '  [%d] %s (%s)  service=%s  port=%s' "$i" "$name" "$tag" "$svc" "$port"
        if [ "$state" = 'not installed' ]; then
            printf '  [service not installed]\n'
        else
            printf '  [%s]\n' "$state"
        fi
        if is_main "$name"; then
            printf '        (main server)\n'
        fi
        i=$((i + 1))
    done
}

next_number() {
    local max=0 d n
    for d in "$SERVER_ROOT"/"$MAIN_FOLDER"[0-9]*; do
        [ -d "$d" ] || continue
        n=${d##*"$MAIN_FOLDER"}
        case "$n" in
            '' | *[!0-9]*) continue ;;
        esac
        [ "$n" -gt "$max" ] && max=$n
    done
    echo $((max + 1))
}

used_ports() {
    (ss -H -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -oP '\d+$' 2>/dev/null | sort -u
}

free_port() {
    local p=4573 used
    used=$(used_ports)
    while [ "$p" -lt 65535 ]; do
        if ! printf '%s\n' "$used" | grep -qx "$p"; then
            local conflict=0 meta port
            for meta in "${META[@]}"; do
                IFS='|' read -r d name svc port id state <<< "$meta"
                if [ "$port" = "$p" ]; then conflict=1; break; fi
            done
            if [ "$conflict" -eq 0 ]; then echo "$p"; return; fi
        fi
        p=$((p + 1))
    done
    echo "$p"
}

new_id() {
    local id
    id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [ -n "$id" ] || id=$(uuidgen 2>/dev/null)
    [ -n "$id" ] || id="${RANDOM}${RANDOM}${RANDOM}-${RANDOM}-${RANDOM}-${RANDOM}-${RANDOM}${RANDOM}${RANDOM}"
    printf '%s' "${id^^}"
}

ask_yes_no() {
    local ans
    while true; do
        printf '%s [Y/N]: ' "$1"
        read -r ans || return 1
        case "$ans" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

choose_items() {
    local title="$1"
    shift
    local items=("$@")
    local n=${#items[@]}
    local ans sel i nums=()
    SELECTED=()
    say ''
    say "$title"
    say ''
    for i in "${!items[@]}"; do
        printf '  [%d] %s\n' "$((i + 1))" "${items[$i]}"
    done
    say ''
    printf 'Select (N=none, A=all, e.g. 1,2 4): '
    read -r ans || return 1
    case "${ans,,}" in
        'a')
            for i in "${!items[@]}"; do SELECTED+=("$i"); done
            ;;
        'n' | '')
            return 1
            ;;
        *)
            nums=$(printf '%s' "$ans" | tr ',;' ' ')
            for sel in $nums; do
                case "$sel" in
                    '' | *[!0-9]*) return 1 ;;
                esac
                i=$((sel - 1))
                [ "$i" -ge 0 ] && [ "$i" -lt "$n" ] || return 1
                SELECTED+=("$i")
            done
            ;;
    esac
    [ ${#SELECTED[@]} -gt 0 ]
}

install_copy() {
    local main_meta='' meta d name svc port id state
    for meta in "${META[@]}"; do
        IFS='|' read -r d name svc port id state <<< "$meta"
        if is_main "$name"; then
            main_meta="$meta"
            break
        fi
    done
    if [ -z "$main_meta" ]; then
        err 'main SePlatform.Data Server installation not found.'
        say 'The main server must be installed first (.deb package).'
        return 1
    fi
    IFS='|' read -r SRC_FOLDER main_name SRC_SVC main_port main_id main_state <<< "$main_meta"

    local num target folder_name svc_name port inst_id main_unit unit dest_origin
    num=$(next_number)
    folder_name="$MAIN_FOLDER$num"
    say ''
    printf 'Folder name for new copy [default: %s]: ' "$folder_name"
    read -r ans || { say 'Installing cancelled.'; return 1; }
    [ -n "$ans" ] && folder_name="$ans"
    target="$SERVER_ROOT/$folder_name"
    if [ -d "$target" ]; then
        err "target folder already exists: $target"
        return 1
    fi
    svc_name="$folder_name"
    printf 'Service name [default: %s]: ' "$svc_name"
    read -r ans || { say 'Installing cancelled.'; return 1; }
    [ -n "$ans" ] && svc_name="$ans"
    port=$(free_port)
    printf 'TCP port [default: %s]: ' "$port"
    read -r ans || { say 'Installing cancelled.'; return 1; }
    [ -n "$ans" ] && port="$ans"
    inst_id=$(new_id)

    local conflict=0
    for meta in "${META[@]}"; do
        IFS='|' read -r d name c_svc c_port c_id c_state <<< "$meta"
        [ "$c_svc" = "$svc_name" ] && { say "Service name already in use: $svc_name"; conflict=1; }
        [ "$c_port" = "$port" ] && { say "Port already in use: $port (by $name)"; conflict=1; }
        [ -n "$c_id" ] && [ "$c_id" = "$inst_id" ] && { say "Instance ID already in use: $inst_id (by $name)"; conflict=1; }
    done
    if [ "$conflict" -ne 0 ]; then
        err "service name / port / instance ID conflict for $svc_name"
        return 1
    fi

    say ''
    say 'Plan for new additional copy:'
    printf '  Source : %s\n' "$SRC_FOLDER"
    printf '  Target : %s\n' "$target"
    printf '  Service: %s\n' "$svc_name"
    printf '  Port   : %s\n' "$port"
    printf '  ID     : %s\n' "$inst_id"
    say ''
    if ! ask_yes_no 'Install additional copy'; then
        say 'Cancelled.'
        return 1
    fi

    main_unit=$(svc_unit "$SRC_SVC")
    unit=$(svc_unit "$svc_name")
    if [ ! -f "$UNIT_DIR/$main_unit" ]; then
        err "main unit file not found: $UNIT_DIR/$main_unit"
        return 1
    fi

    log "Copying server folder: $SRC_FOLDER -> $target"
    if ! cp -R "$SRC_FOLDER" "$target"; then
        fail 'copy failed'
        return 1
    fi

    if ! set_xml_attr "$target/$XML_NAME" install ServiceName "$svc_name"; then
        fail 'cannot edit ServiceName in config XML'
    fi
    if ! set_xml_attr "$target/$XML_NAME" Connection Port "$port"; then
        fail 'cannot edit Port in config XML'
    fi
    set_xml_attr "$target/$XML_NAME" Instance ID "$inst_id"
    json_write_id "$target/$JSON_NAME" "$inst_id"
    say "  Config updated: $target/$XML_NAME"
    say "  Instance ID written to $target/$JSON_NAME"

    if ! cp "$UNIT_DIR/$main_unit" "$UNIT_DIR/$unit"; then
        fail "cannot copy unit file to $UNIT_DIR/$unit"
        return 1
    fi
    sed -i "s|^Description=.*|Description=$svc_name|" "$UNIT_DIR/$unit"
    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$target|" "$UNIT_DIR/$unit"
    sed -i "s|^Environment=LD_LIBRARY_PATH=.*|Environment=LD_LIBRARY_PATH=$target|" "$UNIT_DIR/$unit"
    sed -i "s|^ExecStart=.*|ExecStart=$target/$EXE_NAME|" "$UNIT_DIR/$unit"
    log "Unit file updated: $UNIT_DIR/$unit"

    systemctl daemon-reload
    if systemctl enable "$unit" 2>/dev/null; then
        log "Unit enabled: $unit"
    else
        warn "systemctl enable failed for $unit"
    fi
    if systemctl start "$unit" 2>/dev/null; then
        log "Service started: $unit"
    else
        warn "systemctl start failed for $unit"
    fi
    ok "Additional copy installed: $folder_name"
}

update_copies() {
    local copies=() labels=() meta d name svc port id state i
    for meta in "${META[@]}"; do
        IFS='|' read -r d name svc port id state <<< "$meta"
        if ! is_main "$name"; then
            copies+=("$meta")
            labels+=("$name  $svc  port=$port")
        fi
    done
    if [ ${#copies[@]} -eq 0 ]; then
        say 'No additional copies found to update.'
        return
    fi
    choose_items 'Additional copies to update' "${labels[@]}" || return

    local main_meta=''
    for meta in "${META[@]}"; do
        IFS='|' read -r d name svc port id state <<< "$meta"
        if is_main "$name"; then main_meta="$meta"; break; fi
    done
    if [ -z "$main_meta" ]; then
        err 'main SePlatform.Data Server installation not found.'
        return 1
    fi
    IFS='|' read -r src_dir main_name src_svc main_port main_id main_state <<< "$main_meta"

    if ! ask_yes_no 'Update selected copies (binaries from main server)'; then
        say 'Cancelled.'
        return
    fi

    local new_style=0
    [ -f "$src_dir/$JSON_NAME" ] && new_style=1

    local idx copy copy_name copy_port copy_svc copy_id state unit
    for idx in "${SELECTED[@]}"; do
        copy="${copies[$idx]}"
        IFS='|' read -r copy_dir copy_name copy_svc copy_port copy_id copy_state <<< "$copy"
        if ! [ -f "$copy_dir/$XML_NAME" ] && ! [ -f "$copy_dir/$JSON_NAME" ]; then
            fail "invalid copy folder: $copy_dir"
            continue
        fi
        say ''
        say "  Updating $copy_name..."
        local stop_unit start_after=0
        unit=$(svc_unit "$copy_svc")
        if unit_belongs_to "$copy_svc" "$copy_dir" && systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl stop "$unit" 2>/dev/null
            start_after=1
            log "Stopping service: $copy_svc"
        fi

        local copy_instance_id
        copy_instance_id=$(read_inst_id "$copy_dir")

        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude="$XML_NAME" --exclude="$JSON_NAME" "$src_dir/" "$copy_dir/" 2>/dev/null
        else
            tar -C "$src_dir" -cf - --exclude="$XML_NAME" --exclude="$JSON_NAME" . 2>/dev/null | tar -C "$copy_dir" -xf - 2>/dev/null
        fi
        log 'Binaries synced from ' "$src_dir"

        if [ "$new_style" -eq 1 ]; then
            if [ -n "$copy_instance_id" ]; then
                json_write_id "$copy_dir/$JSON_NAME" "$copy_instance_id"
                log "Instance ID preserved in $copy_dir/$JSON_NAME"
                if [ -f "$copy_dir/$XML_NAME" ]; then
                    comment_xml_instance "$copy_dir/$XML_NAME"
                    log 'Legacy Instance/ID in config XML commented out (migrated to JSON)'
                fi
            else
                warn 'No instance ID found in copy config; keeping existing config files'
            fi
        else
            log 'Main server uses legacy (XML) config; instance ID left in XML'
        fi

        if [ "$start_after" -eq 1 ]; then
            systemctl enable "$unit" 2>/dev/null
            systemctl restart "$unit" 2>/dev/null
            log "Service started: $copy_svc"
        else
            systemctl enable "$unit" 2>/dev/null
            systemctl start "$unit" 2>/dev/null
            log "Service enabled/started: $copy_svc"
        fi
        ok "Updated: $copy_name"
    done
}

remove_copies() {
    local copies=() labels=() meta d name svc port id state i
    for meta in "${META[@]}"; do
        IFS='|' read -r d name svc port id state <<< "$meta"
        if ! is_main "$name"; then
            copies+=("$meta")
            labels+=("$name  $svc  port=$port")
        fi
    done
    if [ ${#copies[@]} -eq 0 ]; then
        say 'No additional copies found to remove.'
        return
    fi
    choose_items 'Additional copies to REMOVE' "${labels[@]}" || return

    if ! ask_yes_no 'Remove selected additional copies (service and folder will be deleted)'; then
        say 'Cancelled.'
        return
    fi

    local idx copy unit
    for idx in "${SELECTED[@]}"; do
        copy="${copies[$idx]}"
        IFS='|' read -r copy_dir copy_name copy_svc copy_port copy_id copy_state <<< "$copy"
        say ''
        say "  Removing $copy_name..."
        unit=$(svc_unit "$copy_svc")
        if unit_belongs_to "$copy_svc" "$copy_dir"; then
            systemctl stop "$unit" 2>/dev/null
            systemctl disable "$unit" 2>/dev/null
            rm -f "$UNIT_DIR/$unit"
            log "Service unregistered: $unit"
        else
            warn "Service $copy_svc is not bound to this copy folder; skipping service removal"
        fi
        rm -rf "$copy_dir"
        log "Removed folder: $copy_dir"
        ok "Removed: $copy_name"
    done
    systemctl daemon-reload
}

main_menu() {
    local choice
    while true; do
        detect
        show_table
        say 'SePlatform.Data Server copies menu:'
        say '  [1] Install a new additional copy (initial installation)'
        say '  [2] Update additional copies from the main server'
        say '  [3] Remove an additional copy'
        say '  [4] Rescan detected copies'
        say '  [5] Exit'
        say ''
        printf 'Select: '
        read -r choice || { say 'Bye.'; return 0; }
        case "$choice" in
            '1') install_copy ;;
            '2') update_copies ;;
            '3') remove_copies ;;
            '4') detect ;;
            '5') say 'Bye.'; return 0 ;;
            *) say 'Please enter 1-5.' ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        err 'This tool requires root (systemd unit files and systemctl). Run with sudo.'
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        err 'systemctl not found; this tool requires systemd.'
        exit 1
    fi

    main_menu
fi