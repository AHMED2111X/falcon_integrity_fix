# FALCON INTEGRITY FIX — كشف تعارضات المديولات (نسخة للقراءة فقط)
# ==============================================================================
# يكتشف المديولات التي قد تتعارض مع FALCON ويُبلِّغ عنها فقط.
# لا يحذف أي مديول، ولا يعطّل أي سكربت، ولا يعدّل أي ملف خارج /data/adb/falcon.
# القرار النهائي للمستخدم — FALCON يعرض النتيجة في الواجهة/السجل.
#
# الاستخدام:
#   sh /data/adb/modules/falcon_integrity_fix/lib/conflicts.sh status
#   sh /data/adb/modules/falcon_integrity_fix/lib/conflicts.sh list
# ==============================================================================

: "${FALCON_DIR:=/data/adb/falcon}"
: "${CONFIG_DIR:=$FALCON_DIR/config}"
: "${MODULES_BASE:=/data/adb/modules}"
: "${CONFLICT_LIST:=$CONFIG_DIR/conflicts.txt}"
: "${REPORT_FILE:=$FALCON_DIR/conflicts_report.txt}"

# --- قراءة الإعدادات ---
cfg_get() {
    _cg_key="$1" _cg_default="$2"
    _cg_val=""
    if [ -f "$CONFIG_DIR/val/$_cg_key.val" ]; then
        IFS= read -r _cg_val < "$CONFIG_DIR/val/$_cg_key.val" 2>/dev/null || true
    fi
    printf '%s' "${_cg_val:-$_cg_default}"
    unset _cg_key _cg_default _cg_val
}

cfg_set() {
    mkdir -p "$CONFIG_DIR/val" 2>/dev/null
    printf '%s' "$2" > "$CONFIG_DIR/val/$1.val" 2>/dev/null
}

log_i() {
    mkdir -p "$FALCON_DIR" 2>/dev/null
    printf '%s [INFO] [conflicts] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$FALCON_DIR/conflicts.log" 2>/dev/null
}

# --- كشف وجود المديول (قراءة فقط) ---
_conflict_detect() {
    case "$1" in
        integritybox) [ -d "$MODULES_BASE/playintegrityfix" ] && [ -d "/data/adb/Box-Brain" ] ;;
        *) [ -d "$MODULES_BASE/$1" ] || [ -d "${MODULES_BASE}_update/$1" ] || [ -d "$MODULES_BASE/.$1" ] || [ -d "${MODULES_BASE}_update/.$1" ] ;;
    esac
}

# --- تقرير نصي (قراءة فقط) ---
conflict_list_text() {
    _cl_found=0
    while IFS='|' read -r _cl_id _cl_name _cl_type _cl_features _cl_scripts; do
        case "$_cl_id" in ''|\#*) continue ;; esac
        _conflict_detect "$_cl_id" || continue
        _cl_found=$((_cl_found + 1))
        printf '%s|%s|%s|%s\n' "$_cl_id" "$_cl_name" "$_cl_type" "${_cl_features:-none}"
    done < "$CONFLICT_LIST"
    [ "$_cl_found" -gt 0 ] || printf '%s\n' "NONE"
}

# --- تقرير JSON للواجهة (قراءة فقط) ---
conflict_status_json() {
    _cs_first=1
    printf '['
    while IFS='|' read -r _cs_id _cs_name _cs_type _cs_features _cs_scripts; do
        case "$_cs_id" in ''|\#*) continue ;; esac
        _conflict_detect "$_cs_id" || continue
        [ "$_cs_first" -eq 0 ] && printf ',' || _cs_first=0
        _cs_choice=$(cfg_get "conflict_$_cs_id" "detect_only")
        printf '{"key":"%s","friendlyName":"%s","detected":true,"type":"%s","features":"%s","mode":"%s"}' \
            "$_cs_id" "$_cs_name" "$_cs_type" "$_cs_features" "$_cs_choice"
    done < "$CONFLICT_LIST"
    printf ']'
}

# --- حفظ تقرير للمستخدم (اختياري، لا يمس أي مديول) ---
write_report() {
    mkdir -p "$FALCON_DIR" 2>/dev/null
    {
        printf '# FALCON — تقرير تعارضات المديولات (%s)\n' "$(date '+%Y-%m-%d %H:%M' 2>/dev/null)"
        printf '# هذه قائمة كشف فقط — لم يُحذف أو يُعطَّل أي مديول.\n'
        conflict_list_text
    } > "$REPORT_FILE" 2>/dev/null
    printf '%s\n' "$REPORT_FILE"
}

if [ ! -f "$CONFLICT_LIST" ]; then
    echo "CONFLICTS=NO_LIST"
    exit 0
fi

case "${1:-status}" in
    status) conflict_status_json; echo "" ;;
    list)   conflict_list_text ;;
    report) write_report; echo "FALCON_CONFLICTS_REPORTED" ;;
    *)      echo "Usage: sh conflicts.sh [status|list|report]" ;;
esac
