#!/system/bin/sh

# ==============================================================================
# FALCON INTEGRITY FIX — تنبيه المستخدم بحالة الكيبوكس (v3.29)
# المطور: ABUFARID | تليجرام: @FALCON_KERNEL
#
# الهدف:
#   إعلام المستخدم — أثناء اللعب أو التصفح، وبدون فتح مدير الروت وبدون فحص
#   SafetyNet يدوياً — بأن الكيبوكس المستخدم توقّف عن العمل (أُبطل من جوجل)
#   أو أنه لم يعد صالحاً.
#
#   التنبيه يظهر كإشعار نظام بارز (Heads-up) فوق التطبيقات والألعاب.
#   وبالإضافة إلى ذلك يُكتب ملف kb_alert ليقرأه الواجهة/مدير الروت.
#
# الاستخدام:
#   sh falcon_kbnotify.sh --auto <FIN> [KS_REV]
#   sh falcon_kbnotify.sh --test
#
#   FIN     : OK | NOCHANGE | REVOKED | FAIL | UNKNOWN   (مخرجات kb_sync.sh)
#   KS_REV  : 1 إن كان الكيبوكس السابق مُبطَلاً وتم استبداله
#
# ملفات الحالة (كلها داخل /data/adb/falcon_keysync):
#   kb_state      — تكتبه kb_sync.sh (OK|REVOKED)
#   notify_state  — آخر حالة أُرسل عنها تنبيه + وقته (لمنع التكرار)
#   kb_alert      — نص التنبيه النشط للواجهة
#   disable_notify — وجوده يوقف التنبيهات نهائياً
#
# ملاحظات:
#   • بلا شبكة وبلا حلقات انتظار — يقرأ الحالة ويكتبها فقط.
#   • لا يمس أي ملف للمستخدم خارج /data/adb/falcon_keysync.
#   • لا يرسل تنبيهاً عند النجاح العادي — فقط عند التوقف أو الاستبدال.
# ==============================================================================

MODDIR="${0%/*}"
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || MODDIR="/data/adb/modules/falcon_integrity_fix"

# --- البحث عن busybox (لأوامر od/base64/sed/tr/grep/awk) ---
BUSYBOX=""
for path in "$MODDIR/busybox" \
            /data/adb/ksu/bin/busybox /data/adb/ksud/bin/busybox \
            /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
            /data/adb/modules/busybox-ndk/system/*/busybox; do
    if [ -x "$path" ] && "$path" true >/dev/null 2>&1; then
        BUSYBOX="$path"
        break
    fi
done
# --- على أندرويد: استخدام busybox (إذا وُجد) للأوامر غير الموثوقة (toybox قد يختلف) ---
if [ -n "$BUSYBOX" ]; then
    od()      { "$BUSYBOX" od "$@"; }
    base64()  { "$BUSYBOX" base64 "$@"; }
    sed()     { "$BUSYBOX" sed "$@"; }
    tr()      { "$BUSYBOX" tr "$@"; }
    grep()    { "$BUSYBOX" grep "$@"; }
    awk()     { "$BUSYBOX" awk "$@"; }
fi
# --- logging helper (debug) ---
dbg() { printf '%s [notify-dbg] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$LOG" 2>/dev/null; }

STATE_DIR="${FALCON_KS_DIR:-/data/adb/falcon_keysync}"
NOTIFY_STATE="$STATE_DIR/notify_state"
ALERT_FILE="$STATE_DIR/kb_alert"
DISABLE_FILE="$STATE_DIR/disable_notify"
LOG="$STATE_DIR/kb_sync.log"

# مهلة التكرار: لا نزعج المستخدم أكثر من مرة كل 6 ساعات للحالة نفسها
COOLDOWN=21600

mkdir -p "$STATE_DIR" 2>/dev/null

logline() {
    printf '%s [notify] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$LOG" 2>/dev/null
}

now_epoch() {
    _n=$(date +%s 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

# --- إرسال إشعار نظام حقيقي (يظهر فوق اللعبة/المتصفح) ---
notify() {
    _title="$1"; _body="$2"; _tag="$3"
    command -v cmd >/dev/null 2>&1 || return 1
    # Android 11+ : -e = heads-up (بارز فوق التطبيقات)
    cmd notification post -e -t "$_title" "$_tag" "$_body" >/dev/null 2>&1 && return 0
    # إصدارات لا تدعم -e
    cmd notification post -t "$_title" "$_tag" "$_body" >/dev/null 2>&1 && return 0
    # الصيغة القديمة
    cmd notification post "$_tag" "$_body" >/dev/null 2>&1 && return 0
    return 1
}

# --- حساب الأيام المتبقية لصلاحية الكيبوكس (أقرب شهادة انتهاءً) ---
# محلل DER مبني على od+awk — لا يحتاج openssl (غير موجود على أندرويد).
# يطبع عدد الأيام (سالب = منتهي) أو لا يطبع شيئاً عند تعذّر التحليل.
kb_expiry_days() {
    _f="$1"
    [ -s "$_f" ] || return 1
    command -v od >/dev/null 2>&1 || return 1

    _td="${TMPDIR:-/data/local/tmp}/falcon_kbx_$$"
    rm -rf "$_td" 2>/dev/null
    mkdir -p "$_td" 2>/dev/null || return 1

    awk -v dir="$_td" '
        /-----BEGIN CERTIFICATE-----/ { i++; out = dir "/c" i ".pem" }
        out != "" { print > out }
        /-----END CERTIFICATE-----/ { out = "" }
    ' "$_f" 2>/dev/null

    _today=$(date +%Y%m%d 2>/dev/null)
    case "$_today" in ''|*[!0-9]*) rm -rf "$_td" 2>/dev/null; return 1 ;; esac

    _min=""
    for _c in "$_td"/c*.pem; do
        [ -s "$_c" ] || continue
        sed '1d;$d' "$_c" 2>/dev/null | tr -d '\r\n' > "$_c.b64" 2>/dev/null
        base64 -d "$_c.b64" > "$_c.der" 2>/dev/null
        [ -s "$_c.der" ] || continue

        _t=$(od -An -v -tx1 "$_c.der" 2>/dev/null | awk '
            { for (i=1;i<=NF;i++) hex = hex $i }
            function hexdec(h, c1, c2) {
                c1 = index("0123456789abcdef", substr(h,1,1)) - 1
                c2 = index("0123456789abcdef", substr(h,2,1)) - 1
                return c1*16 + c2
            }
            function bval(p) { return hexdec(substr(hex, p*2+1, 2)) }
            function tlv(p, l0, nb, i, len) {
                l0 = bval(p+1)
                if (l0 < 128) { CONT = p+2; LEN = l0; return }
                nb = l0 - 128
                len = 0
                for (i=0;i<nb;i++) len = len*256 + bval(p+2+i)
                CONT = p+2+nb; LEN = len
            }
            END {
                tlv(0)
                p = CONT
                tlv(p); p = CONT
                if (bval(p) == 160) { tlv(p); p = CONT + LEN }
                tlv(p); p = CONT + LEN
                tlv(p); p = CONT + LEN
                tlv(p); p = CONT + LEN
                tlv(p)
                v0 = CONT
                tlv(v0)
                n0 = CONT; l0 = LEN
                tlv(n0 + l0)
                na = CONT; nal = LEN
                s = substr(hex, na*2+1, nal*2)
                out = ""
                for (i=1; i<=length(s); i+=2) out = out sprintf("%c", hexdec(substr(s,i,2)))
                print out
            }
        ' 2>/dev/null)

        case "$_t" in ''|*[!0-9]*) continue ;; esac

        # UTCTime = YYMMDDHHMMSSZ (13) · GeneralizedTime = YYYYMMDDHHMMSSZ (15)
        _ymd=$(printf '%s' "$_t" | awk '{
            if (length($0) >= 15) print substr($0,1,8)
            else if (length($0) >= 13) {
                yy = substr($0,1,2) + 0
                y = (yy >= 50) ? 1900 + yy : 2000 + yy
                print y substr($0,3,4)
            }
        }')
        case "$_ymd" in ''|*[!0-9]*) continue ;; esac

        _d=$(awk -v a="$_today" -v b="$_ymd" '
            function jdn(s, y,m,d, a2,y2,m2) {
                y = substr(s,1,4) + 0
                m = substr(s,5,2) + 0
                d = substr(s,7,2) + 0
                a2 = int((14 - m) / 12)
                y2 = y + 4800 - a2
                m2 = m + 12*a2 - 3
                return d + int((153*m2+2)/5) + 365*y2 + int(y2/4) - int(y2/100) + int(y2/400) - 32045
            }
            BEGIN { print jdn(b) - jdn(a) }
        ' 2>/dev/null)
        case "$_d" in ''|*[!0-9-]*) continue ;; esac

        if [ -z "$_min" ] || [ "$_d" -lt "$_min" ] 2>/dev/null; then
            _min="$_d"
        fi
    done

    rm -rf "$_td" 2>/dev/null
    [ -n "$_min" ] || return 1
    printf '%s\n' "$_min"
}

# ============================ تحليل المعطيات ============================MODE="auto"
FIN=""
KSREV="0"

for A in "$@"; do
    case "$A" in
        --test)   MODE="test" ;;
        --auto)   MODE="auto" ;;
        --expiry) MODE="expiry" ;;
        OK|NOCHANGE|REVOKED|FAIL|UNKNOWN) FIN="$A" ;;
        1)       KSREV="1" ;;
    esac
done

TITLE="FALCON INTEGRITY FIX"

# ============================ الوضع التجريبي ============================
if [ "$MODE" = "test" ]; then
    if notify "$TITLE" "✅ تنبيه تجريبي — نظام تنبيه الكيبوكس يعمل على جهازك." "falcon_kb_test"; then
        echo "TEST=OK|notification-sent"
        logline "تنبيه تجريبي أُرسل بنجاح"
        exit 0
    fi
    echo "TEST=FAIL|cmd-notification-unavailable"
    logline "تعذّر إرسال التنبيه التجريبي (cmd notification غير مدعوم على هذا الإصدار)"
    exit 1
fi

# ============================ تحديد الحالة ============================
BODY=""
NEWSTATE=""
BAD=0

case "$FIN" in
    REVOKED)
        NEWSTATE="REVOKED"
        BAD=1
        BODY="🔴 توقّف الكيبوكس: جوجل أبطلت الكيبوكس المستخدم (انتهاء الصلاحية: $KB_EXPIRY_FMT) — Play Integrity معطّل الآن. افتح FALCON لاستبداله."
        ;;
    FAIL)
        NEWSTATE="FAIL"
        BAD=1
        BODY="🟠 لا يوجد كيبوكس صالح على جهازك (انتهاء الصلاحية: $KB_EXPIRY_FMT). Play Integrity لن يمر حتى يُثبَّت كيبوكس سليم — افتح FALCON."
        ;;
    OK)
        NEWSTATE="OK"
        if [ "$KSREV" = "1" ]; then
            BODY="🔄 أُبطل الكيبوكس القديم وتم استبداله تلقائياً بكيبوكس سليم — لا تحتاج لأي إجراء."
        else
            BODY="✅ عاد الكيبوكس للعمل — الحالة سليمة الآن."
        fi
        ;;
    NOCHANGE)
        NEWSTATE="OK"
        BODY="✅ الكيبوكس يعمل بشكل سليم — لا يوجد إبطال."
        ;;
    *)
        NEWSTATE="UNKNOWN"
        ;;
esac

# ============================ فحص صلاحية الشهادات ============================
# يكمّل فحص CRL: قد يكون الكيبوكس غير مُبطَل لكن شهادته انتهت صلاحيتها.
WARN_DAYS=7
if [ -f "$STATE_DIR/expiry_warn_days" ]; then
    WARN_DAYS=$(cat "$STATE_DIR/expiry_warn_days" 2>/dev/null)
fi
case "$WARN_DAYS" in ''|*[!0-9]*) WARN_DAYS=7 ;; esac

KB_FILE="/data/adb/tricky_store/keybox.xml"
[ -s "$KB_FILE" ] || KB_FILE="$MODDIR/keybox.xml"

# --- تاريخ انتهاء الشهادة (أقرب شهادة) ---
# تحليل PEM/DER بـ awk خالص: لا نعتمد على od / base64 / grep / openssl
# (toybox على بعض الأجهزة لا يدعمها — وهذا سبب ظهور exp: unknown سابقاً).
awkc() {
    if [ -n "$BUSYBOX" ]; then "$BUSYBOX" awk "$@"; else awk "$@"; fi
}

# يطبع YYYYMMDD لأقرب شهادة انتهاءً داخل ملف keybox، أو لا يطبع شيئاً.
kb_expiry_ymd() {
    [ -s "$1" ] || return 1
    awkc '
    function b64val(c,   i) { i = index(B64, c); return i ? i - 1 : 0 }
    function hex2(h) { return (index("0123456789abcdef", substr(h,1,1)) - 1) * 16 + (index("0123456789abcdef", substr(h,2,1)) - 1) }
    function decode(s,   n, i, rem, c1, c2, c3, c4, out) {
        sub(/[^A-Za-z0-9+\/].*$/, "", s)
        n = length(s); out = ""
        for (i = 1; i + 3 <= n; i += 4) {
            c1 = b64val(substr(s,i,1)); c2 = b64val(substr(s,i+1,1))
            c3 = b64val(substr(s,i+2,1)); c4 = b64val(substr(s,i+3,1))
            out = out sprintf("%02x%02x%02x", c1*4 + int(c2/16), (c2%16)*16 + int(c3/4), (c3%4)*64 + c4)
        }
        rem = n - i + 1
        c1 = b64val(substr(s,i,1))
        if (rem == 2) { c2 = b64val(substr(s,i+1,1)); out = out sprintf("%02x", c1*4 + int(c2/16)) }
        else if (rem == 3) {
            c2 = b64val(substr(s,i+1,1)); c3 = b64val(substr(s,i+2,1))
            out = out sprintf("%02x%02x", c1*4 + int(c2/16), (c2%16)*16 + int(c3/4))
        }
        return out
    }
    function scan(h,   n, p, tag, ln, s, k, ch, d, best) {
        n = length(h); best = ""
        for (p = 1; p + 3 <= n; p += 2) {
            tag = substr(h, p, 2)
            if (tag != "17" && tag != "18") continue
            ln = hex2(substr(h, p+2, 2))
            if (ln != 13 && ln != 15) continue
            s = ""
            for (k = 0; k < ln; k++) s = s sprintf("%c", hex2(substr(h, p+4+k*2, 2)))
            if (substr(s, ln, 1) != "Z") continue
            if (s !~ /^[0-9]+Z$/) continue
            if (ln == 13) {
                yy = substr(s,1,2) + 0
                d = ((yy >= 50) ? 1900 + yy : 2000 + yy) substr(s,3,4)
            } else { d = substr(s,1,8) }
            if (best == "" || d > best) best = d
        }
        return best
    }
    BEGIN { B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; inb = 0; acc = ""; best = "" }
    /-----BEGIN/ { inb = 1; acc = ""; next }
    /-----END/ {
        if (inb) { e = scan(decode(acc)); if (e != "" && (best == "" || e < best)) best = e }
        inb = 0; acc = ""; next
    }
    { if (inb) acc = acc $0 }
    END {
        if (inb) { e = scan(decode(acc)); if (e != "" && (best == "" || e < best)) best = e }
        print best
    }
    ' "$1" 2>/dev/null
}

# يطبع عدد الأيام المتبقية (سالب = منتهي)
kb_days_left() {
    _tdy=$(date +%Y%m%d 2>/dev/null)
    case "$_tdy" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s\n' "$_tdy" "$1" | awkc '
    function jdn(s,   y,m,d,a2,y2,m2) {
        y = substr(s,1,4) + 0; m = substr(s,5,2) + 0; d = substr(s,7,2) + 0
        a2 = int((14 - m) / 12); y2 = y + 4800 - a2; m2 = m + 12*a2 - 3
        return d + int((153*m2+2)/5) + 365*y2 + int(y2/4) - int(y2/100) + int(y2/400) - 32045
    }
    { print jdn($2) - jdn($1) }
    ' 2>/dev/null
}

EXP_YMD=""
EXP_DAYS=""
KB_EXPIRY_FMT="unknown"
EXP_CACHE="$STATE_DIR/kb_expiry_cache"

for _kbf in /data/adb/tricky_store/keybox.xml "$MODDIR/keybox.xml"; do
    [ -s "$_kbf" ] || continue
    EXP_YMD=$(kb_expiry_ymd "$_kbf")
    case "$EXP_YMD" in ''|*[!0-9]*) EXP_YMD="" ;; esac
    [ -n "$EXP_YMD" ] && break
done

if [ -n "$EXP_YMD" ]; then
    KB_EXPIRY_FMT=$(printf '%s\n' "$EXP_YMD" | awkc '{print substr($1,7,2) "-" substr($1,5,2) "-" substr($1,1,4)}' 2>/dev/null)
    case "$KB_EXPIRY_FMT" in ''|*[!0-9-]*) KB_EXPIRY_FMT="unknown" ;; esac
    EXP_DAYS=$(kb_days_left "$EXP_YMD")
    case "$EXP_DAYS" in ''|*[!0-9-]*) EXP_DAYS="" ;; esac
    printf '%s|%s\n' "$KB_EXPIRY_FMT" "${EXP_DAYS:-}" > "$EXP_CACHE" 2>/dev/null
elif [ -s "$EXP_CACHE" ]; then
    IFS='|' read -r _c1 _c2 < "$EXP_CACHE" 2>/dev/null
    case "$_c1" in
        ''|unknown) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            # ترحيل الكاش القديم من YYYY-MM-DD إلى DD-MM-YYYY
            _cy="${_c1%%-*}"; _cr="${_c1#*-}"; _cm="${_cr%%-*}"; _cd="${_cr#*-}"
            KB_EXPIRY_FMT="$_cd-$_cm-$_cy"
            ;;
        *) KB_EXPIRY_FMT="$_c1" ;;
    esac
    case "$_c2" in ''|*[!0-9-]*) ;; *) EXP_DAYS="$_c2" ;; esac
fi

# (v3.29) احتياطي: التاريخ المكتوب داخل مجلد الوحدة وقت البناء/التثبيت
# (يضمن ظهور التاريخ دائماً حتى لو تعذّر تحليل DER على بعض الأجهزة)
case "$KB_EXPIRY_FMT" in
    ''|unknown)
        for _ef in "$MODDIR/kb_expiry.txt" \
                   /data/adb/modules/falcon_integrity_fix/kb_expiry.txt \
                   /data/adb/modules/falcon_tricky/kb_expiry.txt; do
            [ -s "$_ef" ] || continue
            _ev=$(head -n 1 "$_ef" 2>/dev/null | tr -d ' \t\r\n')
            case "$_ev" in ''|*[!0-9-]*) continue ;; esac
            KB_EXPIRY_FMT="$_ev"
            break
        done
        ;;
esac
# احتساب الأيام المتبقية من الصيغة DD-MM-YYYY عند غيابها
if [ -z "$EXP_DAYS" ]; then
    case "$KB_EXPIRY_FMT" in
        [0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9])
            _fy=${KB_EXPIRY_FMT##*-}
            _fm=${KB_EXPIRY_FMT#*-}; _fm=${_fm%%-*}
            _fd=${KB_EXPIRY_FMT%%-*}
            EXP_DAYS=$(kb_days_left "${_fy}${_fm}${_fd}")
            case "$EXP_DAYS" in ''|*[!0-9-]*) EXP_DAYS="" ;; esac
            ;;
    esac
fi
dbg "expiry: ymd=[$EXP_YMD] fmt=[$KB_EXPIRY_FMT] days=[$EXP_DAYS]"

if [ "$MODE" = "expiry" ]; then
    # حدّث تاريخ الانتهاء في ملف التنبيه النشط (دون تغيير الحالة أو الوقت)
    if [ -s "$ALERT_FILE" ] && [ "$KB_EXPIRY_FMT" != "unknown" ]; then
        IFS='|' read -r _ast _aexp _ats < "$ALERT_FILE" 2>/dev/null
        case "$_ast" in
            ''|*[!A-Za-z]*) ;;
            *) printf '%s|%s|%s\n' "$_ast" "$KB_EXPIRY_FMT" "${_ats:-$(date '+%Y-%m-%d %H:%M')}" > "$ALERT_FILE" 2>/dev/null ;;
        esac
    fi
    printf 'EXPIRY=%s|DAYS=%s\n' "$KB_EXPIRY_FMT" "${EXP_DAYS:-}"
    exit 0
fi

if [ -n "$EXP_DAYS" ]; then
    if [ "$EXP_DAYS" -le 0 ] 2>/dev/null; then
        NEWSTATE="EXPIRED"
        BAD=1
        BODY="⛔ انتهت صلاحية الكيبوكس المستخدم ($KB_EXPIRY_FMT) — Play Integrity سيتوقف. افتح FALCON لتثبيت كيبوكس جديد."
    elif [ "$EXP_DAYS" -le "$WARN_DAYS" ] 2>/dev/null && [ "$BAD" = "0" ]; then
        NEWSTATE="EXPIRING"
        BAD=1
        BODY="⏳ تنتهي صلاحية الكيبوكس المستخدم بعد $EXP_DAYS يوم ($KB_EXPIRY_FMT). حدّثه من FALCON قبل الانتهاء."
    fi
fi

# --- قناة الإيقاف اليدوي ---
if [ -f "$DISABLE_FILE" ]; then
    [ "$BAD" = "1" ] && printf '%s|%s|%s\n' "$NEWSTATE" "$KB_EXPIRY_FMT" "$(date '+%Y-%m-%d %H:%M')" > "$ALERT_FILE" 2>/dev/null
    exit 0
fi

# --- مؤشر دائم للواجهة: يُكتب ما دامت الحالة سيئة ويُحذف عند العودة ---
if [ "$BAD" = "1" ]; then
    printf '%s|%s|%s\n' "$NEWSTATE" "$KB_EXPIRY_FMT" "$(date '+%Y-%m-%d %H:%M')" > "$ALERT_FILE" 2>/dev/null
else
    # احتفظ بملف التنبيه (مع تاريخ الانتهاء) حتى لو كانت الحالة سليمة،
    # ليتمكن مدير الروت من عرض تاريخ انتهاء الكيبوكس دائماً.
    if [ -s "$ALERT_FILE" ]; then
        _prev=$(head -n 1 "$ALERT_FILE" 2>/dev/null | cut -d'|' -f1 | tr -d ' \t\r\n')
        case "$_prev" in
            OK|NOCHANGE) ;;  # تحديث التاريخ (expiry) دون تغيير الحالة
            *) printf 'OK|%s|%s\n' "$KB_EXPIRY_FMT" "$(date '+%Y-%m-%d %H:%M')" > "$ALERT_FILE" 2>/dev/null ;;
        esac
    else
        printf 'OK|%s|%s\n' "$KB_EXPIRY_FMT" "$(date '+%Y-%m-%d %H:%M')" > "$ALERT_FILE" 2>/dev/null
    fi
fi

# ============================ منع التكرار ============================
PREV_STATE=""
PREV_TS=0
if [ -s "$NOTIFY_STATE" ]; then
    read -r PREV_STATE PREV_TS < "$NOTIFY_STATE" 2>/dev/null
fi
case "$PREV_TS" in ''|*[!0-9]*) PREV_TS=0 ;; esac

NOW=$(now_epoch)

SEND=0
CD=$COOLDOWN
case "$NEWSTATE" in EXPIRING|EXPIRED) CD=86400 ;; esac
if [ -n "$BODY" ]; then
    if [ "$KSREV" = "1" ]; then
        # أُبطل الكيبوكس واستُبدل — يُبلَّغ دائماً حتى لو عادت الحالة OK
        SEND=1
    elif [ -z "$PREV_STATE" ] && [ "$BAD" = "0" ]; then
        # أول تشغيل على جهاز سليم — لا داعي لإزعاج المستخدم
        SEND=0
    elif [ "$NEWSTATE" != "$PREV_STATE" ]; then
        SEND=1
    elif [ "$BAD" = "1" ] && [ "$NOW" -gt 0 ] && [ $((NOW - PREV_TS)) -ge "$CD" ]; then
        SEND=1
    fi
fi

[ "$SEND" = "1" ] || exit 0

# ============================ الإرسال ============================
if notify "$TITLE" "$BODY" "falcon_kb"; then
    logline "أُرسل تنبيه حالة الكيبوكس: $NEWSTATE"
else
    logline "تعذّر إرسال إشعار النظام ($NEWSTATE) — التنبيه متاح في الواجهة/وصف الوحدة"
fi

printf '%s %s\n' "$NEWSTATE" "$NOW" > "$NOTIFY_STATE" 2>/dev/null

exit 0
