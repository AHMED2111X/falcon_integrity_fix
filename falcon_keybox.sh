#!/system/bin/sh
# ==============================================================================
# FALCON INTEGRITY FIX — إدارة منفذي الكيبوكس (أساسي + ثانوي)
# المطور: ABUFARID | تليجرام: @FALCON_KERNEL
#
# الفكرة:
#   - المنفذ الأساسي  : /data/adb/falcon/.token_cache   (محفوظ عند الإقلاع، ويُفرض المرفق عند التثبيت/التحديث)
#   - (v3.28) منفذ واحد فقط: /data/adb/falcon/.token_cache
#   - الملف النشط    : /data/adb/tricky_store/keybox.xml (يقرأه محرك Tricky Store)
#   - نسخة المرفق    : /data/adb/falcon/.token_bundle (للكشف فقط)
#   - وسم المصدر     : /data/adb/falcon/.token_source (bundled|custom)
#
#   الاختيار الافتراضي (auto): أساسي صالح ← ثانوي صالح ← مرفق صالح.
#   الترتيب: أساسي صالح ← مرفق صالح.
#   لا يُحذف أي منفذ ولا يُنسخ الثانوي فوق الأساسي إلا بأمر صريح.
#
#   (v3.30) sync --install: يُستدعى من customize.sh فقط عند التثبيت أو التحديث.
#   يفرض كيبوكس الإضافة المرفق على المنفذ الأساسي والمسار النشط، مع أخذ نسخة
#   احتياطية من أي كيبوكس سابق. لا يُستخدم عند الإقلاع حتى لا يُطمس كيبوكس
#   المستخدم المخصص بعد التثبيت.
#
# الاستخدام:
#   sh falcon_keybox.sh status
#   sh falcon_keybox.sh sync [--boot|--early|--install|--force] [--quiet]
#   sh falcon_keybox.sh prefer auto|primary
#   (secondary removed)
#   sh falcon_keybox.sh install-primary <path>
#   (removed)
#   (removed)
#   sh falcon_keybox.sh validate <path>
#   sh falcon_keybox.sh help
#
# ملاحظة: FALCON_KB_ROOT متغير اختبار فقط (يُستخدم في بيئة التطوير).
# ==============================================================================

umask 077

MODDIR="${0%/*}"
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || MODDIR="/data/adb/modules/falcon_integrity_fix"

ROOT="${FALCON_KB_ROOT:-}"
ROOT="${ROOT%/}"

STATE="$ROOT/data/adb/falcon/.slots"
PRIMARY="$ROOT/data/adb/falcon/.token_cache"
SECONDARY="$PRIMARY"   # (v3.28) منفذ واحد فقط
ACTIVE="$ROOT/data/adb/tricky_store/keybox.xml"
TEESIM="$ROOT/data/adb/teesim/keybox.xml"
SNAPSHOT="$ROOT/data/adb/falcon/.token_bundle"
SOURCE="$ROOT/data/adb/falcon/.token_source"
PREF_FILE="$STATE/preferred"
LOG="$STATE/keybox.log"
LOCK="$STATE/.lock"
BACKUP_DIR="$STATE/backups"

BUNDLED="$MODDIR/keybox.xml"
[ -s "$BUNDLED" ] || BUNDLED="$MODDIR/zygisk/keybox.xml"

QUIET=0
LOCKED=0

# ------------------------------------------------------------------------------
# تسجيل وطباعة
# ------------------------------------------------------------------------------
log() {
    local lines
    mkdir -p "$STATE" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOG" 2>/dev/null
    lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' \r\n')
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    if [ "$lines" -gt 300 ]; then
        tail -n 150 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    fi
}

say() {
    [ "$QUIET" = "1" ] || printf '%s\n' "$*"
}

die() {
    say "❌ $*"
    log "خطأ: $*"
    exit 1
}

# ------------------------------------------------------------------------------
# قفل بسيط يمنع تعارض service.sh وpost-fs-data.sh وkb_sync.sh
# ------------------------------------------------------------------------------
acquire_lock() {
    local i owner age now
    [ "$LOCKED" = "1" ] && return 0
    mkdir -p "$STATE" 2>/dev/null
    i=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 10 ]; then
            owner=$(cat "$LOCK/pid" 2>/dev/null)
            case "$owner" in ''|*[!0-9]*) owner="" ;; esac
            age=$(stat -c %Y "$LOCK" 2>/dev/null)
            now=$(date '+%s' 2>/dev/null)
            case "$age" in ''|*[!0-9]*) age="" ;; esac
            case "$now" in ''|*[!0-9]*) now="" ;; esac
            if [ -n "$age" ] && [ -n "$now" ] && [ $((now - age)) -gt 120 ]; then
                log "قفل قديم (أكثر من 120 ثانية) — تجري إزالته"
                rm -rf "$LOCK" 2>/dev/null
                mkdir "$LOCK" 2>/dev/null || return 1
                break
            fi
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                log "القفل مشغول بالعملية $owner — تخطي هذه الدورة"
                return 1
            fi
            rm -rf "$LOCK" 2>/dev/null
            mkdir "$LOCK" 2>/dev/null || return 1
            break
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
    LOCKED=1
    trap 'rm -rf "$LOCK" 2>/dev/null' 0 1 2 15
    return 0
}

# ------------------------------------------------------------------------------
# التحقق البنيوي من الكيبوكس (لا يتحقق من الإبطال CRL — يبقى ذلك لـ kb_sync.sh)
# رموز الخطأ:
#   10 مسار فارغ | 11 رابط رمزي | 12 ليس ملفاً | 14 صغير جداً | 15 كبير جداً
#   16 لا يحتوي AndroidAttestation | 17 غير مغلق | 18 لا يحتوي Keybox
#   19 لا يحتوي Key algorithm | 20 لا يوجد مفتاح خاص | 21 لا توجد شهادة
# ------------------------------------------------------------------------------
kb_validate() {
    local f size
    f="$1"
    [ -n "$f" ] || return 10
    [ ! -L "$f" ] || return 11
    [ -f "$f" ] || return 12
    size=$(wc -c < "$f" 2>/dev/null | tr -d ' \r\n')
    case "$size" in ''|*[!0-9]*) return 12 ;; esac
    [ "$size" -ge 1024 ] || return 14
    [ "$size" -le 2097152 ] || return 15
    grep -q '<AndroidAttestation' "$f" 2>/dev/null || return 16
    grep -q '</AndroidAttestation>' "$f" 2>/dev/null || return 17
    grep -q '<Keybox' "$f" 2>/dev/null || return 18
    grep -q '<Key algorithm=' "$f" 2>/dev/null || return 19
    grep -q 'BEGIN .*PRIVATE KEY' "$f" 2>/dev/null || return 20
    grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null || return 21
    return 0
}

kb_reason() {
    case "$1" in
        10) echo "مسار فارغ" ;;
        11) echo "رابط رمزي مرفوض (Symlink)" ;;
        12) echo "ليس ملفاً عادياً صالحاً" ;;
        14) echo "الملف أصغر من 1KB" ;;
        15) echo "الملف أكبر من 2MB" ;;
        16) echo "لا يحتوي على <AndroidAttestation>" ;;
        17) echo "وسم </AndroidAttestation> غير موجود" ;;
        18) echo "لا يحتوي على <Keybox>" ;;
        19) echo "لا يحتوي على <Key algorithm=...>" ;;
        20) echo "لا يحتوي على مفتاح خاص PRIVATE KEY" ;;
        21) echo "لا يحتوي على شهادة CERTIFICATE" ;;
        *)  echo "خطأ غير معروف ($1)" ;;
    esac
}

slot_size() {
    [ -s "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' \r\n' || echo 0
}

# مقارنة ثنائية مع بديل عند غياب cmp (بعض الأجهزة/البيئات لا توفر cmp).
same_bytes() {
    local h1 h2
    [ -s "$1" ] && [ -s "$2" ] || return 1
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2" 2>/dev/null
        return $?
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        h1=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
        h2=$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)
    elif command -v md5sum >/dev/null 2>&1; then
        h1=$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)
        h2=$(md5sum "$2" 2>/dev/null | cut -d' ' -f1)
    else
        h1=$(cksum < "$1" 2>/dev/null)
        h2=$(cksum < "$2" 2>/dev/null)
    fi
    [ -n "$h1" ] && [ "$h1" = "$h2" ]
}

# مقارنة محتوى متطبيع: تتجاهل المسافات ونهايات الأسطر (CRLF/LF).
# بعض الأدوات تعيد حفظ XML بشكل مختلف قليلاً فيبدو الملف «مخصصاً» زوراً.
same_normalized() {
    local h1 h2
    [ -s "$1" ] && [ -s "$2" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        h1=$(tr -d ' \t\r\n' < "$1" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
        h2=$(tr -d ' \t\r\n' < "$2" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
    elif command -v md5sum >/dev/null 2>&1; then
        h1=$(tr -d ' \t\r\n' < "$1" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1)
        h2=$(tr -d ' \t\r\n' < "$2" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1)
    else
        h1=$(tr -d ' \t\r\n' < "$1" 2>/dev/null | cksum 2>/dev/null)
        h2=$(tr -d ' \t\r\n' < "$2" 2>/dev/null | cksum 2>/dev/null)
    fi
    [ -n "$h1" ] && [ "$h1" = "$h2" ]
}

# (v3.30) بصمة هوية الكيبوكس من كتل الشهادات فقط:
#   تتجاوز BOM، المسافات، نوع الاقتباسات، ترتيب الوسوم/الخصائص، وإعادة تنسيق XML.
#   كيبوكسان لهما نفس سلسلة الشهادات = نفس الكيبوكس عملياً.
kb_cert_sig() {
    local f blob
    f="$1"
    [ -s "$f" ] || return 1
    blob=$(awk '
        /-----BEGIN CERTIFICATE-----/ { on=1; next }
        /-----END CERTIFICATE-----/   { on=0; print ""; next }
        on { gsub(/[ \t\r\n]/, ""); printf "%s", $0 }
    ' "$f" 2>/dev/null | sort 2>/dev/null)
    [ -n "$blob" ] || return 1
    printf '%s\n' "$blob" | cksum 2>/dev/null | awk '{print $1 "-" $2}'
}

same_file() {
    same_bytes "$1" "$2" && return 0
    same_normalized "$1" "$2"
}

# ------------------------------------------------------------------------------
# مصدر الكيبوكس النشط (مرفق / مخصص)
#   المشكلة: المقارنة الثنائية وحدها لا تكفي؛ فقد يكون الملف المرفق قد نُسخ
#   إلى المنفذ الأساسي في إصدار سابق (فيظهر «مخصص» بعد تحديث الإضافة)، أو
#   يكون الكيبوكس المجلوب من الإنترنت مطابقاً بالبايت للكيبوكس المرفق.
#   الحل: وسم صريح يُكتب عند كل عملية تثبيت/جلب، مع الرجوع إلى المقارنة
#   الثنائية مع كل مسارات المرفق واللقطة عند غياب الوسم.
# ------------------------------------------------------------------------------
read_source() {
    local s
    s=""
    [ -s "$SOURCE" ] && s=$(tr -d ' \t\r\n' < "$SOURCE" 2>/dev/null)
    case "$s" in
        bundled|custom) printf '%s\n' "$s" ;;
        *)              printf '\n' ;;
    esac
}

write_source() {
    case "$1" in
        bundled|custom) ;;
        *) return 1 ;;
    esac
    mkdir -p "${SOURCE%/*}" 2>/dev/null
    printf '%s\n' "$1" > "$SOURCE" 2>/dev/null || return 1
    chmod 600 "$SOURCE" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$SOURCE" 2>/dev/null
    return 0
}

# هل الملف نسخة من كيبوكس الإضافة (أي مسار مرفق أو لقطة أو نسخة إصدار سابق)؟
# فحص مسارات متعددة ضروري: أثناء التحديث يكون الإصدار القديم في
# /data/adb/modules/... والجديد في /data/adb/modules_update/...، وقد يكون
# الكيبوكس النشط نسخة من مرفق الإصدار القديم.
is_bundled_copy() {
    local f p sig psig
    f="$1"
    [ -s "$f" ] || return 1
    for p in \
        "$BUNDLED" \
        "$MODDIR/keybox.xml" \
        "$MODDIR/zygisk/keybox.xml" \
        "$ROOT/data/adb/modules/falcon_integrity_fix/keybox.xml" \
        "$ROOT/data/adb/modules/falcon_integrity_fix/zygisk/keybox.xml" \
        "$ROOT/data/adb/modules_update/falcon_integrity_fix/keybox.xml" \
        "$ROOT/data/adb/modules_update/falcon_integrity_fix/zygisk/keybox.xml" \
        "$SNAPSHOT"; do
        [ -s "$p" ] && same_file "$f" "$p" && return 0
    done

    # (v3.30) مطابقة الهوية بالشهادات للنسخ التي أُعيد تنسيقها (BOM/اقتباسات/ترتيب).
    sig=$(kb_cert_sig "$f")
    [ -n "$sig" ] || return 1
    for p in "$BUNDLED" "$SNAPSHOT"; do
        [ -s "$p" ] || continue
        psig=$(kb_cert_sig "$p")
        [ -n "$psig" ] && [ "$sig" = "$psig" ] && return 0
    done
    return 1
}

# وسم المصدر بعد اختيار المنفذ:
#   - bundled صريح ⇒ مرفق.
#   - إن كان الوسم الحالي custom نتحقق من المحتوى: نسخة مرفقة ⇒ يُصحَّح الوسم،
#     وإلا يبقى مخصصاً (لا نُبقي وسماً عالقاً من تثبيت سابق).
#   - وإلا فالمطابقة مع أي نسخة مرفقة ⇒ مرفق، وغير ذلك ⇒ مخصص.
mark_source() {
    local src label cur
    src="$1"
    label="$2"
    cur=$(read_source)
    if [ "$label" = "bundled" ]; then
        write_source bundled
        return 0
    fi
    # الوسم الصريح لا يُغيَّر إلا عند اختيار منفذ «مرفق» صراحةً (أعلاه) أو عند
    # غياب الوسم. هذا يمنع انقلاب «مرفق» إلى «مخصص» بعد تحديث الإضافة حين
    # تتغيّر لقطة المرفق بينما يبقى المنفذ الأساسي نسخة من المرفق السابق.
    if [ "$cur" = "custom" ]; then
        # (v3.30) لا نُبقي وسم «مخصص» عالقاً إذا كان الملف فعلاً نسخة من المرفق.
        is_bundled_copy "$src" && write_source bundled
        return 0
    fi
    [ "$cur" = "bundled" ] && return 0
    if is_bundled_copy "$src"; then
        write_source bundled
    else
        write_source custom
    fi
    return 0
}

# وصف المصدر للعرض في status
source_label() {
    local f cur
    f="$1"
    cur=$(read_source)
    case "$cur" in
        custom)
            # (v3.30) وسم عالق: نتحقق من المحتوى قبل عرض «مخصص».
            if is_bundled_copy "$f"; then echo "المرفق"; else echo "مخصص"; fi
            return 0 ;;
        bundled) echo "المرفق" ; return 0 ;;
    esac
    if is_bundled_copy "$f"; then
        echo "المرفق"
    elif same_file "$f" "$PRIMARY"; then
        echo "الأساسي"
    elif same_file "$f" "$SECONDARY"; then
        echo "الثانوي"
    else
        echo "مخصص"
    fi
}

read_pref() {
    local p
    p=""
    [ -s "$PREF_FILE" ] && p=$(tr -d ' \t\r\n' < "$PREF_FILE" 2>/dev/null)
    case "$p" in
        secondary) echo "secondary" ;;
        *)         echo "auto" ;;
    esac
}

# ------------------------------------------------------------------------------
# نسخ ذري: tmp داخل نفس المجلد ثم mv، مع التحقق والملكية والصلاحيات
# ------------------------------------------------------------------------------
copy_atomic() {
    local src dst mode tmp
    src="$1"
    dst="$2"
    mode="$3"
    tmp="$dst.tmp.$$"
    rm -f "$tmp" 2>/dev/null
    cp -f "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    # (v3.30) same_bytes يتفادى فشل النسخ على الرومات التي لا تحتوي cmp.
    same_bytes "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod "$mode" "$tmp" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$tmp" 2>/dev/null
    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod "$mode" "$dst" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$dst" 2>/dev/null
    return 0
}

apply_active() {
    local src label force
    src="$1"
    label="$2"
    force="$3"
    # (v3.30) force=1 يُستخدم عند التثبيت/التحديث فقط: نتحقق من البنية مسبقاً
    # في force_bundled_main، ونتجاوز رفض CRL لأن المسار القديم مُسح بالفعل
    # والمطلوب فرض المرفق الجديد بلا أي شرط.
    if [ "$force" != "1" ]; then
        # ⛔ (إصلاح) رفض أي كيبوكس مُبطل/كلاسيكي (2 أخضر) — حتى لو جاء من المنفذ عند الإقلاع
        #    الفحص عبر kb_sync.sh --verify: بنية + بصمة الكلاسيكي + قائمة CRL المخزّنة
        if [ -f "$MODDIR/kb_sync.sh" ]; then
            _kbv=$(sh "$MODDIR/kb_sync.sh" --verify="$src" 2>/dev/null)
            case "$_kbv" in
                *VERIFY=BAD*)
                    log "رفض تطبيق $label: $_kbv — أُبقي الكيبوكس النشط الحالي"
                    say "⚠️ رُفض $label: كيبوكس مُبطل/مظلَّل — أُبقي الحالي"
                    return 3 ;;
            esac
        elif grep -q 'AQEEIEO9JGbW5BdGpiEPra/P440ZjzXSuYKaRsNNJr08MfkX' "$src" 2>/dev/null; then
            log "رفض تطبيق $label: الكيبوكس الكلاسيكي (2 أخضر)"
            return 3
        fi
    else
        log "وضع التثبيت/التحديث: تجاوز فحص CRL وفرض $label مباشرة"
    fi
    mkdir -p "${ACTIVE%/*}" 2>/dev/null
    chmod 755 "${ACTIVE%/*}" 2>/dev/null
    copy_atomic "$src" "$ACTIVE" 644 || return 1
    command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$ACTIVE" 2>/dev/null
    if [ -d "${TEESIM%/*}" ]; then
        if copy_atomic "$src" "$TEESIM" 644; then
            command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$TEESIM" 2>/dev/null
            log "تم تحديث كيبوكس TEESim أيضاً"
        else
            log "تنبيه: تعذّر تحديث كيبوكس TEESim"
        fi
    fi
    command -v sync >/dev/null 2>&1 && sync 2>/dev/null
    log "تم تطبيق المنفذ $label على $ACTIVE"
    say "✅ الكيبوكس النشط الآن: $label"
    return 0
}

backup_slot() {
    local src tag dest n old
    src="$1"
    tag="$2"
    [ -s "$src" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    dest="$BACKUP_DIR/$tag-$(date '+%Y%m%d-%H%M%S' 2>/dev/null).dat"
    cp -f "$src" "$dest" 2>/dev/null || return 1
    chmod 600 "$dest" 2>/dev/null
    n=0
    for old in $(ls -t "$BACKUP_DIR/$tag-"*.dat 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -gt 3 ] && rm -f "$old" 2>/dev/null
    done
    log "نسخة احتياطية: $dest"
    return 0
}

# ------------------------------------------------------------------------------
# المزامنة والاختيار
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# (v3.30) فرض كيبوكس الإضافة المرفق عند التثبيت أو التحديث — بلا شرط «تثبيت أول».
#   يُستدعى فقط من customize.sh عبر: sh falcon_keybox.sh sync --install
#   - تثبيت أول: لا يوجد منفذ ⇒ يُثبَّت المرفق أساسياً ونشطاً.
#   - ترقية فوق إصدار سابق: يُؤخذ احتياطي من الأساسي/النشط ثم يُفرض المرفق الجديد.
#   - لا يُستدعى عند الإقلاع كي لا يُطمس كيبوكس المستخدم المخصص لاحقاً.
# ------------------------------------------------------------------------------
force_bundled_main() {
    local src rc legacy
    src="$BUNDLED"
    rc=0
    kb_validate "$src" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log "تعذّر فرض الكيبوكس المرفق: $(kb_reason "$rc")"
        say "⚠️ الكيبوكس المرفق غير صالح — $(kb_reason "$rc")"
        return 1
    fi

    mkdir -p "$STATE" "$BACKUP_DIR" "$ROOT/data/adb/falcon" "$ROOT/data/adb/tricky_store" 2>/dev/null
    chmod 700 "$ROOT/data/adb/falcon" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$ROOT/data/adb/falcon" 2>/dev/null
    acquire_lock || return 2

    # (v3.30) مسح الوسم القديم أولاً: لا يبقى «custom» عالقاً إن فشل الفرض لاحقاً.
    rm -f "$SOURCE" 2>/dev/null

    # نسخة احتياطية من كل كيبوكس سابق قبل أي استبدال
    if [ -s "$PRIMARY" ]; then
        backup_slot "$PRIMARY" "primary" 2>/dev/null || log "تنبيه: تعذّر حفظ نسخة احتياطية للأساسي"
    fi
    if [ -s "$ACTIVE" ] && ! same_file "$ACTIVE" "$PRIMARY"; then
        backup_slot "$ACTIVE" "active" 2>/dev/null || log "تنبيه: تعذّر حفظ نسخة احتياطية للنشط"
    fi
    if [ -s "$TEESIM" ] && ! same_file "$TEESIM" "$PRIMARY" && ! same_file "$TEESIM" "$ACTIVE"; then
        backup_slot "$TEESIM" "teesim" 2>/dev/null || log "تنبيه: تعذّر حفظ نسخة احتياطية لـ TEESim"
    fi
    legacy="$ROOT/data/adb/falcon/.token_cache2"
    if [ -s "$legacy" ]; then
        backup_slot "$legacy" "legacy" 2>/dev/null || log "تنبيه: تعذّر حفظ نسخة احتياطية للمنفذ القديم"
    fi

    # (v3.30) حذف بقايا الكيبوكس القديم من Tricky Store حتى لا يُقرأ أي ملف سابق.
    # الملف النشط نفسه يُستبدل ذرياً بالكيبوكس المرفق في apply_active أدناه.
    rm -f "$ACTIVE.bak" "$TEESIM.bak" \
          "$ROOT/data/adb/tricky_store/keybox.xml.bak" \
          "$ROOT/data/adb/tricky_store"/*.bak "$legacy" 2>/dev/null

    # 1) تطبيق المرفق على المسار النشط — بفرض كامل بلا رفض CRL (force=1)
    if ! apply_active "$src" "المرفق (فرض التثبيت/التحديث)" 1; then
        log "فشل فرض الكيبوكس المرفق على المسار النشط"
        say "⚠️ رُفض الكيبوكس المرفق — أُبقي الكيبوكس النشط السابق"
        return 3
    fi

    # 2) تثبيته في المنفذ الأساسي الدائم حتى يبقى بعد إعادة التشغيل
    if ! copy_atomic "$src" "$PRIMARY" 600; then
        log "تنبيه: تعذّر حفظ الكيبوكس المرفق في المنفذ الأساسي"
        say "⚠️ طُبّق الكيبوكس المرفق مؤقتاً — تعذّر حفظه كمنفذ أساسي"
        return 4
    fi
    copy_atomic "$src" "$SNAPSHOT" 600 2>/dev/null || log "تنبيه: تعذّر تحديث لقطة الكيبوكس المرفق"
    printf 'auto\n' > "$PREF_FILE" 2>/dev/null

    # 3) الوسم والصلاحيات بعد نجاح الفرض فعلياً
    chmod 600 "$PRIMARY" "$SNAPSHOT" 2>/dev/null
    write_source bundled
    log "تم فرض كيبوكس الإضافة المرفق (تثبيت/تحديث)"
    say "✅ فُرِض الكيبوكس المرفق داخل الإضافة على المنفذ الأساسي والمسار النشط"
    return 0
}

sync_main() {
    local mode pref chosen rc rc2 src ACTIVE_OLD_BUNDLE PRIMARY_OLD_BUNDLE
    mode="$1"
    # (v3.30) وضع التثبيت/التحديث: فرض كيبوكس الإضافة المرفق بلا أي شرط.
    if [ "$mode" = "install" ]; then
        force_bundled_main
        return $?
    fi
    mkdir -p "$STATE" "$BACKUP_DIR" "$ROOT/data/adb/falcon" "$ROOT/data/adb/tricky_store" 2>/dev/null
    acquire_lock || return 2

    pref=$(read_pref)

    # 1) لقطة من الكيبوكس المرفق للكشف لاحقاً (لا تُستخدم للتطبيق)
    # قبل تحديث اللقطة: إن كان النشط مطابقاً للقطة القديمة فهو كيبوكس الإضافة
    # السابق وليس كيبوكس مستخدم — لا يجوز تبنّيه كمنفذ أساسي.
    ACTIVE_OLD_BUNDLE=0
    # (v3.30) لا نثق بوسم custom وحده: نتحقق من هوية المحتوى حتى لا يُتبنّى
    # كيبوكس مرفق قديم كمنفذ مخصص بسبب وسم عالق من تثبيت سابق.
    if [ -s "$ACTIVE" ] && is_bundled_copy "$ACTIVE"; then
        ACTIVE_OLD_BUNDLE=1
    fi
    # المنفذ الأساسي قد يكون نسخة من كيبوكس الإضافة السابق (بعد ترقيته).
    # نكتشف ذلك قبل تحديث اللقطة حتى لا يتحول إلى «مخصص» زوراً.
    PRIMARY_OLD_BUNDLE=0
    if [ -s "$PRIMARY" ] && is_bundled_copy "$PRIMARY"; then
        PRIMARY_OLD_BUNDLE=1
        # وسم وقائي مبكر قبل تحديث اللقطة: إن انقطعت المزامنة لاحقاً يبقى
        # المنفذ الأساسي معروفاً كنسخة مرفق ولا ينقلب إلى «مخصص».
        write_source bundled
    fi
    if [ -s "$BUNDLED" ] && ! same_file "$BUNDLED" "$SNAPSHOT"; then
        copy_atomic "$BUNDLED" "$SNAPSHOT" 600 2>/dev/null || log "تنبيه: تعذّر حفظ لقطة الكيبوكس المرفق"
    fi

    # 2) تبنّي كيبوكس Tricky Store المخصص إذا كان المنفذ الأساسي غير صالح
    rc=0
    kb_validate "$PRIMARY" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$ACTIVE_OLD_BUNDLE" -eq 0 ]; then
        rc2=0
        kb_validate "$ACTIVE" || rc2=$?
        if [ "$rc2" -eq 0 ] && \
           ! same_file "$ACTIVE" "$BUNDLED" && \
           ! same_file "$ACTIVE" "$SNAPSHOT" && \
           ! same_file "$ACTIVE" "$SECONDARY"; then
            if copy_atomic "$ACTIVE" "$PRIMARY" 600; then
                log "تم تبنّي كيبوكس Tricky Store المخصص كمنفذ أساسي"
                write_source custom
            fi
        fi
    fi

    # 3) اختيار المنفذ
    chosen=""
    if [ "$pref" = "secondary" ]; then
        rc=0; kb_validate "$SECONDARY" || rc=$?
        [ "$rc" -eq 0 ] && chosen="secondary"
    fi
    if [ -z "$chosen" ]; then
        rc=0; kb_validate "$PRIMARY" || rc=$?
        [ "$rc" -eq 0 ] && chosen="primary"
    fi
    if [ -z "$chosen" ]; then
        rc=0; kb_validate "$SECONDARY" || rc=$?
        [ "$rc" -eq 0 ] && chosen="secondary"
    fi
    if [ -z "$chosen" ] && [ -s "$BUNDLED" ]; then
        rc=0; kb_validate "$BUNDLED" || rc=$?
        [ "$rc" -eq 0 ] && chosen="bundled"
    fi

    if [ -z "$chosen" ]; then
        log "لا يوجد كيبوكس صالح (أساسي/ثانوي/مرفق)"
        say "❌ لا يوجد كيبوكس صالح في أي منفذ."
        return 3
    fi

    case "$chosen" in
        primary)   src="$PRIMARY" ;;
        secondary) src="$SECONDARY" ;;
        bundled)   src="$BUNDLED" ;;
    esac

    # 4) إن كان النشط مطابقاً بالفعل لا نعيد الكتابة (حماية من تغيير الطوابع)
    rc=0; kb_validate "$ACTIVE" || rc=$?
    if [ "$rc" -eq 0 ] && same_file "$src" "$ACTIVE"; then
        chmod 644 "$ACTIVE" 2>/dev/null
        command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$ACTIVE" 2>/dev/null
        if [ -d "${TEESIM%/*}" ] && ! same_file "$src" "$TEESIM"; then
            copy_atomic "$src" "$TEESIM" 644 2>/dev/null
        fi
        if [ "$chosen" = "primary" ] && [ "$PRIMARY_OLD_BUNDLE" -eq 1 ] && \
           [ "$(read_source)" != "custom" ]; then
            write_source bundled
        else
            mark_source "$src" "$chosen"
        fi
        log "المنفذ النشط مطابق مسبقاً: $chosen"
        say "ℹ️ الكيبوكس النشط مطابق مسبقاً للمنفذ: $chosen"
        return 0
    fi

    # 5) تطبيق المنفذ المختار
    apply_active "$src" "$chosen" || { log "فشل تطبيق المنفذ $chosen"; return 4; }
    if [ "$chosen" = "primary" ] && [ "$PRIMARY_OLD_BUNDLE" -eq 1 ] && \
       [ "$(read_source)" != "custom" ]; then
        write_source bundled
    else
        mark_source "$src" "$chosen"
    fi

    # 6) تحذير فقط عند غياب أحد نوعي المفاتيح (بعض الكيبوكسات قد تحتوي نوعاً واحداً)
    grep -q '<Key algorithm="ecdsa"' "$src" 2>/dev/null || log "تنبيه: المنفذ $chosen لا يحتوي مفتاح ecdsa"
    grep -q '<Key algorithm="rsa"' "$src" 2>/dev/null || log "تنبيه: المنفذ $chosen لا يحتوي مفتاح rsa"

    # 7) تنبيه عند اختيار منفذ غير الأساسي
    if [ "$chosen" != "primary" ]; then
        say "ℹ️ المنفذ الأساسي محفوظ كما هو: $PRIMARY"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# الأوامر
# ------------------------------------------------------------------------------
status_main() {
    local pref rc label
    pref=$(read_pref)
    say "════════════════════════════════════════════════════════"
    say " FALCON KEYBOX SLOTS — حالة المنفذين"
    say "════════════════════════════════════════════════════════"

    rc=0; kb_validate "$PRIMARY" || rc=$?
    if [ "$rc" -eq 0 ]; then
        say "✅ الأساسي  : $PRIMARY ($(slot_size "$PRIMARY") بايت)"
    elif [ -e "$PRIMARY" ] || [ -L "$PRIMARY" ]; then
        say "❌ الأساسي  : $PRIMARY — $(kb_reason "$rc")"
    else
        say "➖ الأساسي  : غير موجود ($PRIMARY)"
    fi

    rc=0; kb_validate "$SECONDARY" || rc=$?
    if [ "$rc" -eq 0 ]; then
        say "✅ الثانوي  : $SECONDARY ($(slot_size "$SECONDARY") بايت)"
    elif [ -e "$SECONDARY" ] || [ -L "$SECONDARY" ]; then
        say "❌ الثانوي  : $SECONDARY — $(kb_reason "$rc")"
    else
        say "➖ الثانوي  : غير موجود ($SECONDARY)"
    fi

    if [ -s "$BUNDLED" ]; then
        rc=0; kb_validate "$BUNDLED" || rc=$?
        if [ "$rc" -eq 0 ]; then
            say "✅ المرفق   : $BUNDLED ($(slot_size "$BUNDLED") بايت)"
        else
            say "❌ المرفق   : $BUNDLED — $(kb_reason "$rc")"
        fi
    else
        say "➖ المرفق   : غير موجود"
    fi

    rc=0; kb_validate "$ACTIVE" || rc=$?
    if [ "$rc" -eq 0 ]; then
        label=$(source_label "$ACTIVE")
        say "🔑 النشط    : $ACTIVE ($(slot_size "$ACTIVE") بايت) ← $label"
    elif [ -e "$ACTIVE" ] || [ -L "$ACTIVE" ]; then
        say "❌ النشط    : $ACTIVE — $(kb_reason "$rc")"
    else
        say "➖ النشط    : غير موجود ($ACTIVE)"
    fi

    say "⚙️  التفضيل  : $pref"
    if [ -d "${TEESIM%/*}" ]; then
        say "🔁 TEESim   : موجود — ستتم مزامنة الملف النشط معه"
    else
        say "➖ TEESim   : غير مثبت"
    fi
    say "📄 السجل    : $LOG"

    rc=0; kb_validate "$ACTIVE" || rc=$?
    return "$rc"
}

validate_main() {
    local f rc
    f="$1"
    [ -n "$f" ] || die "الاستخدام: sh falcon_keybox.sh validate <path>"
    rc=0; kb_validate "$f" || rc=$?
    if [ "$rc" -eq 0 ]; then
        say "✅ ملف كيبوكس صالح: $f ($(slot_size "$f") بايت)"
        return 0
    fi
    say "❌ ملف غير صالح: $f — $(kb_reason "$rc")"
    return 1
}

prefer_main() {
    local p
    p="$1"
    case "$p" in
        auto|primary) p="auto" ;;
        secondary) ;;
        *) die "الاستخدام: sh falcon_keybox.sh prefer auto|primary" ;;
    esac
    mkdir -p "$STATE" 2>/dev/null
    printf '%s\n' "$p" > "$PREF_FILE" 2>/dev/null || die "تعذّر حفظ التفضيل"
    log "تم تعيين التفضيل إلى $p"
    say "✅ التفضيل الآن: $p"
    sync_main manual
}


set_primary() {
    local src rc
    src="$1"
    [ -n "$src" ] || die "الاستخدام: sh falcon_keybox.sh install-primary <path>"
    rc=0; kb_validate "$src" || rc=$?
    [ "$rc" -eq 0 ] || die "ملف غير صالح: $(kb_reason "$rc")"
    mkdir -p "$STATE" "$BACKUP_DIR" 2>/dev/null
    acquire_lock || die "تعذّر الحصول على القفل"
    backup_slot "$PRIMARY" "primary" || log "تنبيه: تعذّر حفظ نسخة احتياطية للأساسي"
    copy_atomic "$src" "$PRIMARY" 600 || die "تعذّر حفظ المنفذ الأساسي"
    chmod 600 "$PRIMARY" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$PRIMARY" 2>/dev/null
    # أمر تثبيت يدوي ⇒ مخصص، إلا إن كان الملف نفسه هو كيبوكس الإضافة المرفق.
    if [ -s "$BUNDLED" ] && same_file "$src" "$BUNDLED"; then
        write_source bundled
    else
        write_source custom
    fi
    printf 'auto\n' > "$PREF_FILE" 2>/dev/null
    log "تم تعيين المنفذ الأساسي من $src"
    say "✅ تم حفظ المنفذ الأساسي: $PRIMARY"
    sync_main manual
}

# مصدر الكيبوكس النشط — مخرجات ثابتة للواجهة: BUNDLED | CUSTOM | NONE
source_main() {
    local rc
    rc=0; kb_validate "$ACTIVE" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "NONE"
        return 1
    fi
    case "$(read_source)" in
        custom)
            # (v3.30) وسم عالق من تثبيت سابق: نتحقق من المحتوى قبل الحكم.
            if is_bundled_copy "$ACTIVE"; then echo "BUNDLED"; else echo "CUSTOM"; fi
            ;;
        bundled) echo "BUNDLED" ;;
        *)
            if is_bundled_copy "$ACTIVE"; then
                echo "BUNDLED"
            else
                echo "CUSTOM"
            fi
            ;;
    esac
    return 0
}

usage() {
    cat <<'EOF'
الاستخدام:
  sh falcon_keybox.sh status
  sh falcon_keybox.sh sync [--boot|--early|--install|--force] [--quiet]
  (--install: فرض كيبوكس الإضافة المرفق عند التثبيت/التحديث)
  sh falcon_keybox.sh prefer auto|primary
  (secondary removed)
  sh falcon_keybox.sh install-primary <path>
  (removed)
  (removed)
  sh falcon_keybox.sh validate <path>
  sh falcon_keybox.sh source
  sh falcon_keybox.sh same <a> <b>
  sh falcon_keybox.sh help

المنافذ:
  الأساسي  : /data/adb/falcon/.token_cache
  الثانوي  : /data/adb/falcon/.token_cache2
  النشط    : /data/adb/tricky_store/keybox.xml
EOF
}

# ------------------------------------------------------------------------------
# نقطة الدخول
# ------------------------------------------------------------------------------
CMD="$1"
[ $# -gt 0 ] && shift

case "$CMD" in
    status)
        status_main
        ;;
    sync)
        MODE="manual"
        while [ $# -gt 0 ]; do
            case "$1" in
                --boot)   MODE="boot"; QUIET=1 ;;
                --early)  MODE="early"; QUIET=1 ;;
                --install) MODE="install" ;;
                --force)  MODE="force" ;;
                --quiet)  QUIET=1 ;;
                *)        die "خيار غير معروف: $1" ;;
            esac
            shift
        done
        sync_main "$MODE"
        ;;
    prefer)
        prefer_main "$1"
        ;;
    install-primary)
        set_primary "$1"
        ;;
    validate)
        validate_main "$1"
        ;;
    source)
        source_main
        ;;
    same)
        # (v3.30) مقارنة كيبوكسين: بايت/تطبيع/شهادات — للاستخدام الداخلي.
        [ -n "$1" ] && [ -n "$2" ] || exit 1
        same_file "$1" "$2" && exit 0
        _sig1=$(kb_cert_sig "$1")
        _sig2=$(kb_cert_sig "$2")
        [ -n "$_sig1" ] && [ "$_sig1" = "$_sig2" ] && exit 0
        exit 1
        ;;
    help|-h|--help|'')
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac