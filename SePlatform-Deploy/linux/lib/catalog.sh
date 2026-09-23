# catalog.sh — источник (zip/папка), .deb-entries, выбор кандидата по манифесту.

MANIFEST=''
SOURCE=''
SOURCE_TYPE=''

declare -a PRODUCTS=()     # запись продукта: поля через \x1f
declare -a PRODUCT_DEPS=() # запись зависимости: id\x1fkind\x1fpackage\x1fминим.версия\x1fописание\x1fblocking
declare -a ENTRIES=()      # .deb-записи в источнике (пути/entry внутри zip)
declare -a ENTRY_BASE=()   # базовые имена

# состояние по индексу продукта:
declare -a CAND_ENTRY=() CAND_BASE=() CAND_PKG=() CAND_VER=() CAND_ARCH=() CAND_PATH=()
declare -a INST_PKG=() INST_VER=() INST_ARCH=()
declare -a STATUS=() ERROR=()
declare -a DEPS_JSON=()     # признак наличия зависимостей
declare -a BLOCKED_REASON=()
declare -a DEP_CHECK_TEXT=()

F_PROD=()   # временный массив для prod_val

# ---------- парсинг манифеста ----------

json_products() {
    # печатает записи продуктов через \x1f
    python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
for p in d.get('products', []):
    def g(k, dfl=''):
        v = p.get(k, dfl)
        return dfl if v is None else v
    def lst(k):
        v = p.get(k) or []
        return '|'.join(str(x) for x in v)
    req = p.get('required', False)
    deps = len(p.get('dependencies') or [])
    print('\x1f'.join([
        str(g('id')), str(g('displayName')), str(g('group')),
        ('1' if str(req).lower() in ('true', '1', 'yes') else '0'),
        str(g('debPattern')), str(g('packagePattern')), lst('localePreference'),
        str(g('archCode', 'amd64')), str(g('order', 500)),
        lst('services'), lst('processes'), str(deps)
    ]))
PY
}

json_deps() {
    python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
for p in d.get('products', []):
    pid = p.get('id', '')
    for dd in (p.get('dependencies') or []):
        blocking = str(dd.get('blocking', True)).lower() in ('true', '1', 'yes')
        print('\x1f'.join([pid, str(dd.get('kind','')), str(dd.get('package','')),
                           str(dd.get('minVersion','')), str(dd.get('description','')),
                           ('1' if blocking else '0')]))
PY
}

load_manifest() {
    local path="$1" i
    MANIFEST="$path"
    [ -f "$MANIFEST" ] || fatal "manifest not found: $MANIFEST"
    command -v python3 >/dev/null 2>&1 || fatal 'python3 required to parse manifest-linux.json'
    mapfile -t PRODUCTS < <(json_products)
    if [ ${#PRODUCTS[@]} -eq 0 ]; then
        fatal "manifest has no valid products: $MANIFEST"
    fi
    mapfile -t PRODUCT_DEPS < <(json_deps 2>/dev/null)
    # дефолтные массивы
    for i in "${!PRODUCTS[@]}"; do
        STATUS[$i]='UNKNOWN'; ERROR[$i]=''; CAND_BASE[$i]=''
        CAND_PATH[$i]=''; CAND_PKG[$i]=''; CAND_VER[$i]=''; INST_PKG[$i]=''; INST_VER[$i]=''
        DEP_CHECK_TEXT[$i]=''
    done
    log "Manifest loaded: $(basename "$MANIFEST") (${#PRODUCTS[@]} products)"
}

prod_val() {
    # prod_val IDX FIELD
    IFS=$'\x1f' read -ra F_PROD <<< "${PRODUCTS[$1]}"
    echo "${F_PROD[$2]:-}"
}

prod_deps_count() { prod_val "$1" 11; }

prod_services() {
    local v
    v=$(prod_val "$1" 9)
    echo "${v//|/ }"
}

prod_processes() {
    local v
    v=$(prod_val "$1" 10)
    echo "${v//|/ }"
}

# ---------- источник ----------

detect_source_type() {
    # detect_source_type PATH
    local p="$1"
    if [ -d "$p" ]; then
        SOURCE_TYPE='dir'
    elif [ -f "$p" ] && [[ "$p" == *.zip ]]; then
        SOURCE_TYPE='zip'
        command -v unzip >/dev/null 2>&1 || fatal "unzip not found; archive is ZIP: $p"
    else
        fatal "source not found or unsupported (need a directory or ZIP): $p"
    fi
}

collect_entries() {
    ENTRIES=(); ENTRY_BASE=()
    local e b
    if [ "$SOURCE_TYPE" = 'zip' ]; then
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            b=$(basename "$e")
            ENTRIES+=("$e"); ENTRY_BASE+=("$b")
        done < <(unzip -Z1 "$SOURCE" 2>/dev/null | grep -iE '\.deb$')
    else
        while IFS= read -r e; do
            b=$(basename "$e")
            ENTRIES+=("$e"); ENTRY_BASE+=("$b")
        done < <(find "$SOURCE" -type f -iname '*.deb' 2>/dev/null | sort)
    fi
    log "Found ${#ENTRIES[@]} .deb entrie(s) in $SOURCE ($SOURCE_TYPE)"
}

# ---------- выбор кандидата ----------

locale_rank_list=()
arch_token_list=()

set_locale_prefs() { IFS='|' read -ra locale_rank_list <<< "$1"; }
set_arch_tokens()  { IFS='|' read -ra arch_token_list <<< "$1"; }

locale_rank() {
    local base="$1" lb="${1,,}" n=${#locale_rank_list[@]}
    local i tok best=$n
    [ $n -eq 0 ] && { echo 0; return; }
    for i in "${!locale_rank_list[@]}"; do
        tok=${locale_rank_list[$i],,}
        case "$lb" in
            *"-${tok}-"*) echo "$i"; return ;;
        esac
    done
    case "$lb" in
        *"-ru-"*)
            for i in "${!locale_rank_list[@]}"; do
                case "${locale_rank_list[$i],,}" in ru*) echo "$i"; return ;; esac
            done ;;
        *"-en-"*)
            for i in "${!locale_rank_list[@]}"; do
                case "${locale_rank_list[$i],,}" in en*) echo "$i"; return ;; esac
            done ;;
    esac
    echo "$n"
}

arch_ok() {
    local base="$1" lb="${1,,}" t
    for t in "${arch_token_list[@]}"; do
        [ -n "$t" ] || continue
        case "$lb" in
            *"${t,,}"*) return 0 ;;
        esac
    done
    return 1
}

version_from_filename() {
    local base="$1" ver=''
    if [[ $base =~ ([0-9]+(\.[0-9]+)+(\+[A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*)?) ]]; then
        ver="${BASH_REMATCH[1]}"
        ver="${ver%.deb}"
        case "${ver,,}" in
            *.x86_64 | *.amd64 | *.i386 | *.i686 | *.aarch64 | *.arm64 | *.arm | *.all | *.any)
                ver="${ver%.*}" ;;
        esac
    fi
    echo "$ver"
}

read_deb_control() {
    # read_deb_control FILE -> в глобальные OUT_PKG OUT_VER OUT_ARCH
    local file="$1"
    OUT_PKG=''; OUT_VER=''; OUT_ARCH=''
    command -v dpkg-deb >/dev/null 2>&1 || return 1
    OUT_PKG=$(dpkg-deb -f "$file" Package 2>/dev/null)
    OUT_VER=$(dpkg-deb -f "$file" Version 2>/dev/null)
    OUT_ARCH=$(dpkg-deb -f "$file" Architecture 2>/dev/null)
    [ -n "$OUT_PKG" ] || return 1
    return 0
}

select_candidate() {
    local idx="$1"
    [ ${#ENTRIES[@]} -eq 0 ] && { STATUS[$idx]='NO_DEB'; ERROR[$idx]="No matching .deb in source (no .deb found)"; return 0; }
    local pattern base entry rank best_rank=2147483647 cand='' candbase='' archok composite
    pattern=$(prod_val "$idx" 4)
    set_locale_prefs "$(default_locale_prefs "$idx")"
    set_arch_tokens "$CFG_ARCH_LIST"
    local i
    for i in "${!ENTRIES[@]}"; do
        base="${ENTRY_BASE[$i]}"
        case "$base" in
            $pattern) ;;
            *) continue ;;
        esac
        rank=$(locale_rank "$base")
        if arch_ok "$base"; then composite=$(( rank )); else composite=$(( rank + 100000 )); fi
        if [ "$composite" -lt "$best_rank" ]; then
            best_rank=$composite
            cand="${ENTRIES[$i]}"
            candbase="$base"
        fi
    done
    if [ -z "$cand" ]; then
        STATUS[$idx]='NO_DEB'
        ERROR[$idx]="No matching .deb in source (pattern: $pattern)"
        return 0
    fi
    CAND_ENTRY[$idx]="$cand"
    CAND_BASE[$idx]="$candbase"
    # пробуем прочитать control (если файл доступен локально)
    if [ "$SOURCE_TYPE" = 'dir' ]; then
        read_deb_control "$cand" && {
            CAND_PKG[$idx]="$OUT_PKG"; CAND_VER[$idx]="$OUT_VER"; CAND_ARCH[$idx]="$OUT_ARCH"
        }
    fi
    if [ -z "${CAND_PKG[$idx]}" ]; then
        CAND_VER[$idx]=$(version_from_filename "$candbase")
    fi
    return 0
}

default_locale_prefs() {
    # default_locale_prefs IDX  -> locale-список
    local idx="$1" v
    if [ -n "${GLOBAL_LOCALE:-}" ]; then
        echo "$GLOBAL_LOCALE"
        return
    fi
    v=$(prod_val "$idx" 6)
    if [ -n "$v" ]; then
        echo "$v"
    else
        echo "${CFG['localePreference']:-ru_RU|ru|en_US|en}"
    fi
}

extract_candidate() {
    # extract_candidate IDX DEST_DIR
    local idx="$1" dest="$2"
    local entry="${CAND_ENTRY[$idx]}" base="${CAND_BASE[$idx]}"
    [ -n "$entry" ] || return 1
    if [ "$SOURCE_TYPE" = 'zip' ]; then
        unzip -j -o "$SOURCE" "$entry" -d "$dest" >/dev/null 2>&1 || return 1
    else
        cp -f "$entry" "$dest/$base" 2>/dev/null || return 1
    fi
    CAND_PATH[$idx]="$dest/$base"
    return 0
}

build_actions() {
    # для каждого продукта: кандидат, извлечение, чтение control, статус по инвентаризации
    local idx name
    for idx in "${!PRODUCTS[@]}"; do
        name=$(prod_val "$idx" 1)
        select_candidate "$idx"
        if [ "${STATUS[$idx]}" = 'NO_DEB' ]; then
            log "$name: no matching .deb (NO_DEB)"
            continue
        fi
        # извлекаем кандидата, чтобы прочитать контрольные поля и собрать путь для установки
        if [ -z "${CAND_PKG[$idx]}" ]; then
            if extract_candidate "$idx" "$DEB_TMP_DIR"; then
                if read_deb_control "${CAND_PATH[$idx]}"; then
                    CAND_PKG[$idx]="$OUT_PKG"; CAND_VER[$idx]="$OUT_VER"; CAND_ARCH[$idx]="$OUT_ARCH"
                fi
            else
                warn "$name: cannot extract candidate ${CAND_BASE[$idx]}"
            fi
            if [ -z "${CAND_VER[$idx]}" ]; then
                CAND_VER[$idx]=$(version_from_filename "${CAND_BASE[$idx]}")
            fi
        fi
        log "$name: candidate=${CAND_BASE[$idx]:-none} pkg=${CAND_PKG[$idx]:-?:} ver=${CAND_VER[$idx]:-?:}"
        resolve_installed_status "$idx"
    done
}