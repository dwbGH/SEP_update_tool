# common.sh — общее: выходные коды, логирование, ввод, JSON, сравнение версий, отчёт.

EXIT_OK=0
EXIT_ERRORS=1
EXIT_ABORTED=2
EXIT_PREREQ=3
EXIT_BAD_PARAMS=4

NONE=''
ESC=$(printf '\033')
NO_COLOR=0

SESSION_DIR=''
LOG_FILE=''
REPORT_FILE=''

declare -gA CFG=()

# ---------- цвета / вывод ----------

say() { printf '%s\n' "$*"; }
log() { local t; t=$(date '+%Y-%m-%d %H:%M:%S'); printf '%s [INFO] %s\n' "$t" "$*"; if [ -n "$LOG_FILE" ]; then printf '%s [INFO] %s\n' "$t" "$*" >> "$LOG_FILE"; fi; }
warn() { local t; t=$(date '+%Y-%m-%d %H:%M:%S'); printf '%s [WARN] %s\n' "$t" "$*"; if [ -n "$LOG_FILE" ]; then printf '%s [WARN] %s\n' "$t" "$*" >> "$LOG_FILE"; fi; }
err()  { local t; t=$(date '+%Y-%m-%d %H:%M:%S'); printf '%s [ERROR] %s\n' "$t" "$*" >&2; if [ -n "$LOG_FILE" ]; then printf '%s [ERROR] %s\n' "$t" "$*" >> "$LOG_FILE"; fi; }
fatal() { err "$*"; exit $EXIT_BAD_PARAMS; }

ok()   { printf '  [OK] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

# ---------- ini-подобный парсинг config (плоский JSON) ----------

get_json_string() {
    # get_json_string '<json-file>' '<key>'  -> печатает строковое значение
    local file="$1" key="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" "$key" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    sys.exit(1)
v=d.get(sys.argv[2],'')
if v is None: v=''
if isinstance(v,bool): v='1' if v else '0'
print(v)
PY
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
        return 0
    fi
    return 1
}

require_json_tool() {
    if command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1; then
        return 0
    fi
    err 'JSON-парсер не найден: установите python3 или jq.'
    return 1
}

get_json_list() {
    # get_json_list FILE KEY -> pipe-joined список
    local file="$1" key="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" "$key" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    sys.exit(1)
v=d.get(sys.argv[2],[]) or []
if isinstance(v,str): v=[v]
print('|'.join(str(x) for x in v))
PY
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k]? // empty | if type=="array" then (map(tostring)|join("|")) else . end' "$file" 2>/dev/null
        return 0
    fi
    return 1
}

# cfg_bool KEY DEFAULT -> печатает '1' или '0' (нормализация булевых значений из JSON)
cfg_bool() {
    local key="$1" dflt="${2:-0}" v
    v="${CFG[$key]:-$dflt}"
    case "${v,,}" in
        1 | true | yes | on) echo 1 ;;
        0 | false | no | off | '') echo 0 ;;
        *) echo "$dflt" ;;
    esac
}

load_config() {
    # load_config FILE — заполняет ассоциативный массив CFG
    local file="$1" k
    [ -f "$file" ] || fatal "config not found: $file"
    CFG['config']="$file"
    for k in defaultArchive logRoot tempRoot installTimeoutSeconds uninstallTimeoutSeconds \
             keepTempOnError cleanupTempOnSuccess warnOnNewerVersion continueOnComponentError \
             requireRoot installWithApt purgeOnUninstall; do
        CFG[$k]=$(get_json_string "$file" "$k")
    done
    CFG['localePreference']=$(get_json_list "$file" localePreference)
    CFG['preferArch']=$(get_json_list "$file" preferArch)
    [ -n "${CFG['logRoot']}" ] || CFG['logRoot']='/var/log/SePlatform/Deployment'
    [ -n "${CFG['tempRoot']}" ] || CFG['tempRoot']='/tmp/SePlatform-Deploy'
    [ -n "${CFG['localePreference']}" ] || CFG['localePreference']='ru_RU|ru|en_US|en'
    [ -n "${CFG['preferArch']}" ] || CFG['preferArch']='amd64|x86_64|all|any'
    log "Config loaded: $file"
}

# ---------- сравнение версий (dpkg --compare-versions) ----------

deb_compare() {
    # deb_compare VERSION OP VERSION ; OP: lt gt le ge eq ne
    dpkg --compare-versions "$1" "$3" "$2" 2>/dev/null
}

# ---------- ввод ----------

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

# выбрать элементы по списку, результат в глобальном массиве SELECTED (индексы)
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

# ---------- сессия и отчёт ----------

new_session() {
    # new_session BASE_LOG_ROOT ARCHIVE_NAME
    local base="$1" name="$2" stamp
    stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    SESSION_DIR="$base/$stamp"
    mkdir -p "$SESSION_DIR" || { err "cannot create session dir: $SESSION_DIR"; return 1; }
    LOG_FILE="$SESSION_DIR/Deployment.log"
    REPORT_FILE="$SESSION_DIR/report.json"
    : > "$LOG_FILE"
    log "Session started: $SESSION_DIR"
    log "Source: $name"
}

write_report() {
    # write_report EXIT_CODE RESULT [ROWS_FILE] — строки компонентов ("\x1f"-разделённые поля, по одной на строку)
    local exit_code="$1" result="$2"
    local rows_file="${3:-$SESSION_DIR/components.tsv}"
    [ -n "$REPORT_FILE" ] || return 0
    [ -f "$rows_file" ] || return 0
    python3 - "$REPORT_FILE" "$exit_code" "$result" "$rows_file" <<'PY'
import json, os, sys
report_file, exit_code, result, rows_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
env = os.environ
counters = {}
def ic(k): counters[k]=int(env.get(k,0))
for k in ('CountUpdated','CountInstalled','CountUninstalled','CountSkipped','CountFailed','CountOk'):
    ic(k)
comps=[]
for line in open(rows_file, encoding='utf-8'):
    line=line.rstrip('\n')
    if not line: continue
    f=line.split('\x1f')
    comps.append({
        'id': f[0], 'displayName': f[1], 'status': f[2],
        'package': f[3], 'oldVersion': f[4], 'newVersion': f[5],
        'installFile': f[6], 'installExitCode': f[7],
        'uninstallExitCode': f[8], 'verified': f[9] == '1', 'error': f[10]
    })
data={
  'manifestVersion': '1.0',
  'session': {
    'startTime': os.environ.get('SESSION_START',''),
    'endTime': os.environ.get('SESSION_END',''),
    'hostname': os.environ.get('HOSTNAME',''),
    'user': os.environ.get('USER','root'),
    'archive': os.environ.get('SOURCE_DISPLAY',''),
    'sourceType': os.environ.get('SOURCE_TYPE',''),
    'mode': os.environ.get('DEPLOY_MODE',''),
    'dryRun': os.environ.get('DRY_RUN','0')=='1'
  },
  'counters': counters,
  'exitCode': int(exit_code),
  'result': result,
  'components': comps
}
with open(report_file,'w',encoding='utf-8') as fh:
    json.dump(data,fh,ensure_ascii=False,indent=2)
PY
    return 0
}

# ---------- прочее ----------

get_machine_os() {
    # строка типа: Debian GNU/Linux 12 (bookworm) x86_64
    local pretty='' arch
    if [ -f /etc/os-release ]; then
        pretty=$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?$/\1/p' /etc/os-release | head -n1)
    fi
    [ -n "$pretty" ] || pretty=$(uname -s)
    arch=$(uname -m)
    printf '%s %s' "$pretty" "$arch"
}