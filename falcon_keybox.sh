#!/system/bin/sh
# ==============================================================================
# FALCON INTEGRITY FIX — إدارة منفذي الكيبوكس (أساسي + ثانوي)
# المطور: ABUFARID | تليجرام: @FALCON_KERNEL
#
# الفكرة:
#   - المنفذ الأساسي  : /data/adb/falcon/.token_cache   (لا يُستبدل تلقائياً أبداً)
#   - (v3.28) منفذ واحد فقط: /data/adb/falcon/.token_cache
#   - الملف النشط    : /data/adb/tricky_store/keybox.xml (يقرأه محرك Tricky Store)
#   - نسخة المرفق    : /data/adb/falcon/.token_bundle (للكشف فقط)
#
#   الاختيار الافتراضي (auto): أساسي صالح ← ثانوي صالح ← مرفق صالح.
#   الترتيب: أساسي صالح ← مرفق صالح.
#   لا يُحذف أي منفذ ولا يُنسخ الثانوي فوق الأساسي إلا بأمر صريح.
#
# الاستخدام:
#   sh falcon_keybox.sh status
#   sh falcon_keybox.sh sync [--boot|--early|--force] [--quiet]
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

same_file() {
    [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2" 2>/dev/null
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
    cmp -s "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod "$mode" "$tmp" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$tmp" 2>/dev/null
    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    chmod "$mode" "$dst" 2>/dev/null
    command -v chown >/dev/null 2>&1 && chown 0:0 "$dst" 2>/dev/null
    return 0
}

apply_active() {
    local src label
    src="$1"
    label="$2"
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
sync_main() {
    local mode pref chosen rc rc2 src ACTIVE_OLD_BUNDLE
    mode="$1"
    mkdir -p "$STATE" "$BACKUP_DIR" "$ROOT/data/adb/falcon" "$ROOT/data/adb/tricky_store" 2>/dev/null
    acquire_lock || return 2

    pref=$(read_pref)

    # 1) لقطة من الكيبوكس المرفق للكشف لاحقاً (لا تُستخدم للتطبيق)
    # قبل تحديث اللقطة: إن كان النشط مطابقاً للقطة القديمة فهو كيبوكس الإضافة
    # السابق وليس كيبوكس مستخدم — لا يجوز تبنّيه كمنفذ أساسي.
    ACTIVE_OLD_BUNDLE=0
    if [ -s "$ACTIVE" ] && [ -s "$SNAPSHOT" ] && same_file "$ACTIVE" "$SNAPSHOT"; then
        ACTIVE_OLD_BUNDLE=1
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
        log "المنفذ النشط مطابق مسبقاً: $chosen"
        say "ℹ️ الكيبوكس النشط مطابق مسبقاً للمنفذ: $chosen"
        return 0
    fi

    # 5) تطبيق المنفذ المختار
    apply_active "$src" "$chosen" || { log "فشل تطبيق المنفذ $chosen"; return 4; }

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
        label="مخصص"
        if same_file "$ACTIVE" "$PRIMARY"; then
            label="الأساسي"
        elif same_file "$ACTIVE" "$SECONDARY"; then
            label="الثانوي"
        elif same_file "$ACTIVE" "$BUNDLED"; then
            label="المرفق"
        fi
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
    printf 'auto\n' > "$PREF_FILE" 2>/dev/null
    log "تم تعيين المنفذ الأساسي من $src"
    say "✅ تم حفظ المنفذ الأساسي: $PRIMARY"
    sync_main manual
}



usage() {
    cat <<'EOF'
الاستخدام:
  sh falcon_keybox.sh status
  sh falcon_keybox.sh sync [--boot|--early|--force] [--quiet]
  sh falcon_keybox.sh prefer auto|primary
  (secondary removed)
  sh falcon_keybox.sh install-primary <path>
  (removed)
  (removed)
  sh falcon_keybox.sh validate <path>
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
    help|-h|--help|'')
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac