# inventory.sh — инвентаризация установленных .deb, статусы, проверка зависимостей.

declare -a INV_PKG=() INV_VER=() INV_ARCH=() INV_STATUS=()

dpkg_inventory() {
    INV_PKG=(); INV_VER=(); INV_ARCH=(); INV_STATUS=()
    command -v dpkg-query >/dev/null 2>&1 || fatal 'dpkg-query not found; is this a Debian/Ubuntu system?'
    local line p v a s
    while IFS=$'\t' read -r p v a s; do
        case "$s" in
            *'install ok installed'*) ;;
            *) continue ;;
        esac
        INV_PKG+=("$p"); INV_VER+=("$v"); INV_ARCH+=("$a"); INV_STATUS+=("$s")
    done < <(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' 2>/dev/null)
    log "Installed packages scanned: ${#INV_PKG[@]}"
}

find_installed_by_regex() {
    # find_installed_by_regex ERE  -> печатает индексы подходящих пакетов
    local rx="$1" i
    local -a out=()
    shopt -s nocasematch
    for i in "${!INV_PKG[@]}"; do
        if [[ "${INV_PKG[$i]}" =~ $rx ]]; then
            out+=("$i")
        fi
    done
    shopt -u nocasematch
    printf '%s\n' "${out[@]}"
}

find_installed_by_package() {
    # find_installed_by_package PKG [CAND_IDX] -> индексы точных пакетов; [столбец сравнения]
    local want="$1" wantl="${1,,}" i
    local -a out=()
    for i in "${!INV_PKG[@]}"; do
        if [ "${INV_PKG[$i],,}" = "$wantl" ]; then
            out+=("$i")
        fi
    done
    printf '%s\n' "${out[@]}"
}

dpkg_query_version() {
    # dpkg_query_version PKG -> версия (или пусто)
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

known_package_installed() {
    # known_package_installed PKG [MIN] [MAX?] -> 0 ok, 1 not ok
    local pkg="$1" minv="$2" found
    found=$(dpkg_query_version "$pkg")
    [ -n "$found" ] || return 1
    if [ -n "$minv" ]; then
        dpkg --compare-versions "$found" ge "$minv" 2>/dev/null || return 1
    fi
    return 0
}

resolve_installed_status() {
    # resolve_installed_status IDX — использует глобальный инвентарь и кандидата
    local idx="$1" cand_pkg="${CAND_PKG[$idx]}" cand_ver="${CAND_VER[$idx]}"
    local rx hits inst malformed
    rx=$(prod_val "$idx" 5)
    [ -n "$rx" ] || rx="^${cand_pkg}$"
    hits=$(find_installed_by_regex "$rx")
    if [ -z "${hits// /}" ]; then
        STATUS[$idx]='MISSING'
        CAND_BASE[$idx]="${CAND_BASE[$idx]}"
        return 0
    fi
    # точный пакет = пакет кандидата (регистр независимо); иначе первый подходящий
    local found_hit='' h instl candl="${cand_pkg,,}"
    if [ -n "$cand_pkg" ]; then
        for h in $hits; do
            instl="${INV_PKG[$h],,}"
            if [ "$instl" = "$candl" ]; then found_hit=$h; break; fi
            # имя пакета может нести локаль-суффикс (_ru_ru и т.п.) — сравниваем без него
            if [[ "$instl" =~ ^(.*)_[a-z]{2,3}_[a-z]{2,3}$ ]]; then
                if [ "${BASH_REMATCH[1]}" = "$candl" ]; then found_hit=$h; break; fi
            fi
            if [[ "$candl" =~ ^(.*)_[a-z]{2,3}_[a-z]{2,3}$ ]]; then
                if [ "$instl" = "${BASH_REMATCH[1]}" ]; then found_hit=$h; break; fi
            fi
        done
    fi
    if [ -z "$found_hit" ] && [ -n "$cand_pkg" ]; then
        # установлен только другой локаль-вариант пакета: считаем отсутствующим (MISSING)
        STATUS[$idx]='MISSING'
        return 0
    fi
    [ -n "$found_hit" ] || found_hit=$(printf '%s\n' "$hits" | head -n1)
    inst=$found_hit
    INST_PKG[$idx]="${INV_PKG[$inst]}"
    INST_VER[$idx]="${INV_VER[$inst]}"
    INST_ARCH[$idx]="${INV_ARCH[$inst]}"
    if [ -z "$cand_ver" ]; then
        STATUS[$idx]='UPDATE'
        return 0
    fi
    if dpkg --compare-versions "$cand_ver" gt "${INST_VER[$idx]}" 2>/dev/null; then
        STATUS[$idx]='UPDATE'
    elif dpkg --compare-versions "$cand_ver" eq "${INST_VER[$idx]}" 2>/dev/null; then
        STATUS[$idx]='OK'
    else
        STATUS[$idx]='SKIP_NEWER'
        ERROR[$idx]='Installed version is newer than the archive'
    fi
}

# ---------- зависимости ----------

check_product_dependencies() {
    # check_product_dependencies IDX
    local idx="$1" id deps_count
    id=$(prod_val "$idx" 0)
    deps_count=$(prod_deps_count "$idx")
    [ "$deps_count" -gt 0 ] || return 0
    [ ${#PRODUCT_DEPS[@]} -gt 0 ] || return 0
    local drow d fields ok_req blocking texts=() has_block=0 miss=()
    for drow in "${PRODUCT_DEPS[@]}"; do
        IFS=$'\x1f' read -ra d <<< "$drow"
        [ "${d[0]}" = "$id" ] || continue
        local kind="${d[1]}" pkg="${d[2]}" minv="${d[3]}" desc="${d[4]}" blk="${d[5]}"
        local ok=0 found=''
        case "$kind" in
            dpkg)
                found=$(dpkg_query_version "$pkg")
                if [ -n "$found" ]; then
                    if [ -z "$minv" ] || dpkg --compare-versions "$found" ge "$minv" 2>/dev/null; then ok=1; else ok=0; fi
                fi
                ;;
            command)
                if command -v "$pkg" >/dev/null 2>&1; then ok=1; found='present'; fi
                ;;
            *)
                ok=1; found='unsupported kind, skipped'
                ;;
        esac
        if [ "$ok" -eq 1 ]; then
            texts+=("[OK] $desc (found: ${found:-present})")
        else
            texts+=("[ERROR] $desc not satisfied (found: ${found:-not installed}, min: ${minv:-any})")
            [ "$blk" = '1' ] && { has_block=1; miss+=("${pkg}${minv:+ >= $minv}"); }
        fi
    done
    DEP_CHECK_TEXT[$idx]="$(printf '%s\n' "${texts[@]}")"
    if [ "$has_block" -eq 1 ]; then
        local reason='Prerequisites not satisfied'
        if [ ${#miss[@]} -gt 0 ]; then
            reason="$reason: ${miss[*]}"
        fi
        STATUS[$idx]='BLOCKED'
        BLOCKED_REASON[$idx]="$reason"
        ERROR[$idx]="$reason"
    fi
}

apply_status_from_deps() {
    # после инвентаризации: для UPDATE/MISSING проверяем зависимости
    local idx
    for idx in "${!PRODUCTS[@]}"; do
        case "${STATUS[$idx]}" in
            UPDATE | MISSING) check_product_dependencies "$idx" ;;
        esac
    done
}